import AppKit
import JavaScriptCore
import PDFKit
import SurimonoCore
import Testing

@testable import SurimonoRendering

@MainActor
struct MermaidRenderingTests {
    private var settings: RenderSettings {
        RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: "body { font-family: serif; }"),
            preset: HTMLCleanupPreset(id: "none", name: "None"))
    }

    @Test("時間を使い切った描画スクリプトは残った原文を一件の確認にまとめる")
    func deadlineWithoutWebView() throws {
        let context = try #require(JSContext())
        context.evaluateScript(
            """
            const sources = Array.from({length: 3}, () => ({parentElement: {classList: new Set()}}));
            const document = {body: {}, querySelectorAll(selector) {
              if (selector === '.mermaid-block > .mermaid-source') return sources;
              if (selector === '.mermaid-error.mermaid-timeout > .mermaid-source') {
                return sources.filter(s => ['mermaid-error', 'mermaid-timeout'].every(c => s.parentElement.classList.has(c)));
              }
              return [];
            }};
            const mermaid = {initialize() {}, mermaidAPI: {defaultConfig: {}}};
            const performance = {now: () => 1};
            const getComputedStyle = () => ({fontFamily: 'serif'});
            (async () => { \(MermaidScript.rendering(budgetMilliseconds: 0)) })();
            """)
        let json = context.evaluateScript(
            "JSON.stringify((() => { \(PrintIssueAnchors.javaScript(themed: true)) })())")
        #expect(context.exception == nil)
        let data = Data(try #require(json?.toString()).utf8)
        let issues = try JSONDecoder().decode([PrintIssue].self, from: data)
        #expect(issues.map(\.kind) == [.mermaidTimeout])
        #expect(issues.map(\.detail) == ["3"])
    }

    @Test("時間切れで原文を残した図は確認に合計を一度だけ載せる", .timeLimit(.minutes(1)))
    func timedOutIssues() async throws {
        let block = "<div class='mermaid-block'><pre class='mermaid-source'>graph LR</pre></div>"
        let renderer = DocumentRenderer(paginateWithResult: { request in
            let deadline = MermaidScript.rendering(budgetMilliseconds: 0)
            let preparation = """
                globalThis.mermaid = { initialize() {}, mermaidAPI: {defaultConfig: {}} };
                await (async () => { \(deadline) })();
                \(request.preparationScript ?? "")
                """
            return try await WebPaginator().paginateWithResult(
                request.source, pageSize: request.pageSize,
                margins: request.margins, allowsJavaScript: false, preparationScript: preparation)
        })
        let source = DocumentSource(data: Data((block + block).utf8), format: .markdown)
        let pages = try await renderer.prepare(source, settings: settings)
        #expect(pages.issues.filter { $0.kind == .mermaidTimeout }.map(\.detail) == ["2"])
        #expect(!pages.issues.contains { $0.kind == .mermaid })
    }

    @Test("図のブロックを作る読み取りの文書だけがMermaidの準備を要求し、HTML・テキスト・CSV・図のない文書は要求しない")
    func eligibleFormats() async throws {
        let block = "<div class=\"mermaid-block\"><pre class=\"mermaid-source\">flowchart LR</pre></div>"
        let cell = { (source: String) -> String in
            let notebook: [String: Any] = [
                "cells": [["cell_type": "markdown", "metadata": [String: Any](), "source": "# 見出し\n\n" + source]],
                "metadata": [String: Any](), "nbformat": 4, "nbformat_minor": 5,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: notebook)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        let inputs: [(DocumentFormat, String, Bool)] = [
            (.markdown, "```mermaid\nflowchart LR\nA --> B\n```", true),
            (.org, "#+begin_src mermaid\nflowchart LR\nA --> B\n#+end_src", true),
            (.notebook, cell("```mermaid\nflowchart LR\nA --> B\n```"), true),
            (.markdown, "# 図のない文書", false),
            (.notebook, cell("図のない文書"), false),
            (.html, block, false),
            (.plainText, "```mermaid\nflowchart LR\nA --> B\n```\n" + block, false),
            (.csv, "kind,source\nmermaid,\"" + block.replacingOccurrences(of: "\"", with: "\"\"") + "\"", false),
        ]
        for (format, text, expected) in inputs {
            let renderer = DocumentRenderer(paginate: { request in
                #expect(request.rendersMermaid == expected)
                if expected { #expect(!request.allowsJavaScript) }
                return try RenderingFixtures.pdf()
            })
            _ = try await renderer.render(DocumentSource(data: Data(text.utf8), format: format), settings: settings)
        }
    }

    @Test("図のないDOMではMermaid本体を読み込まない", .timeLimit(.minutes(1)))
    func noLibraryWithoutDiagrams() async throws {
        _ = NSApplication.shared
        let paginator = WebPaginator()
        let result = try await paginator.paginateWithResult(
            .html("<p>本文</p>", baseURL: nil), pageSize: CGSize(width: 595, height: 842),
            margins: .uniform(millimeters: 15), allowsJavaScript: false,
            preparationScript: "return typeof mermaid;", rendersMermaid: true)
        #expect(paginator.mermaidLoadCount == 0)
        #expect(result.preparationResult == "undefined")
    }

    @Test("数式のラベルを含む図・HTMLでしか描けない種類の図・長すぎる図は削らずに原文を残す", .timeLimit(.minutes(1)))
    func unsupportedDiagramsKeepSource() async throws {
        _ = NSApplication.shared
        let math = "sequenceDiagram\n    A->>B: Solve: $$x^2$$"
        let events = "eventmodeling\n  tf 01 ui Catalogue\n  tf 02 cmd RequestLoan\n  tf 03 evt LoanRequested"
        let long = "flowchart LR\n    A[" + String(repeating: "あ", count: MermaidScript.maxTextSize) + "]"
        let blocks = [math, events, long, "flowchart LR\n    A --> B"].map {
            "<div class=\"mermaid-block\"><pre class=\"mermaid-source\">\($0)</pre></div>"
        }
        // Wrapped as the app's common.css wraps it: WebKit's print process ended on the unbroken 50,000-character
        // line, which printed a blank page before the paginator noticed that the process had ended.
        let style = "<style>.mermaid-source { white-space: pre-wrap; overflow-wrap: anywhere; }</style>"
        let result = try await WebPaginator().paginateWithResult(
            .html(style + blocks.joined(), baseURL: nil), pageSize: CGSize(width: 595, height: 842),
            margins: .uniform(millimeters: 15), allowsJavaScript: false,
            preparationScript: """
                return JSON.stringify({
                  errors: Array.from(document.querySelectorAll('.mermaid-error > .mermaid-source'))
                    .map(source => source.textContent.slice(0, 20)),
                  figures: (() => { \(PrintIssueAnchors.javaScript(themed: true)) })()
                    .filter(issue => issue.kind === 'mermaid' && issue.element === 'figure').length,
                  diagrams: document.querySelectorAll('.mermaid-block > svg').length});
                """, rendersMermaid: true)
        let json = try #require(result.preparationResult)
        let values = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(values["diagrams"] as? Int == 1)
        let errors = try #require(values["errors"] as? [String])
        #expect(errors.count == 3)
        #expect(errors.first?.hasPrefix("sequenceDiagram") == true)
        #expect(errors.last?.hasPrefix("flowchart LR") == true)
        // Only the diagrams that were read but need HTML are reported apart from the syntax errors.
        #expect(values["figures"] as? Int == 2)
    }

    @Test("図をSVGにしてから確認し壊れた図の原文と変更の印を残す", .timeLimit(.minutes(1)))
    func diagramsAndFailure() async throws {
        _ = NSApplication.shared
        let text = """
            ```mermaid
            flowchart LR
              A[開始] --> B[完了]
            ```

            ```mermaid
            flowchart LR
              A[broken
            ```

            ```mermaid
            sequenceDiagram
              participant A as 受付
              participant B as 工房
              A->>B: 印刷依頼
            ```

            <script>document.body.innerHTML = 'PAGE SCRIPT RAN';</script>
            """
        let paginator = WebPaginator()
        var markedPasses = 0
        let renderer = DocumentRenderer(paginateWithResult: { request in
            let inspection = """
                const result = await (async () => { \(request.preparationScript ?? "") })();
                const diagrams = document.querySelectorAll('.mermaid-block > svg');
                const errors = document.querySelectorAll('.mermaid-error > .mermaid-source');
                return JSON.stringify({result, diagrams: diagrams.length, errors: errors.length,
                  labels: Array.from(diagrams).map(svg => svg.textContent).join(' '),
                  foreignObjects: document.querySelectorAll('.mermaid-block foreignObject').length,
                  marked: !!document.querySelector('.mermaid-block[data-surimono-block] > svg'),
                  raw: errors[0]?.textContent,
                  fits: Array.from(diagrams).every(svg =>
                    svg.getBoundingClientRect().width <= document.body.getBoundingClientRect().width + 2)});
                """
            let result = try await paginator.paginateWithResult(
                request.source, pageSize: request.pageSize, margins: request.margins,
                allowsJavaScript: request.allowsJavaScript, preparationScript: inspection,
                readsPageRules: request.readsPageRules, drawsBackground: request.drawsBackground,
                rendersMermaid: request.rendersMermaid)
            let json = try #require(result.preparationResult)
            let values = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            #expect(values["diagrams"] as? Int == 2)
            #expect(values["errors"] as? Int == 1)
            #expect(values["foreignObjects"] as? Int == 0)
            if values["marked"] as? Bool == true { markedPasses += 1 }
            #expect(values["fits"] as? Bool == true)
            #expect((values["labels"] as? String)?.contains("開始") == true)
            #expect((values["labels"] as? String)?.contains("印刷依頼") == true)
            #expect((values["raw"] as? String)?.contains("A[broken") == true)
            return WebPaginator.Result(document: result.document, preparationResult: values["result"] as? String)
        })
        var settings = settings
        settings.markdownChanges = MarkdownChanges.marks(
            from: text.replacingOccurrences(of: "開始", with: "始め"), to: text)
        let result = try await renderer.render(
            DocumentSource(data: Data(text.utf8), format: .markdown), settings: settings)
        #expect(paginator.mermaidLoadCount == 2)
        #expect(markedPasses == 1)
        #expect(!result.changeMarks.isEmpty)
        #expect(result.logicalDocument.pageCount > 0)
        #expect(result.issues.map(\.kind) == [.mermaid])
        #expect(result.issues.first?.pageNumber != nil)
        #expect(result.issues.first?.detail.contains("A[broken") == true)
        #expect(result.logicalDocument.string?.contains("PAGE SCRIPT RAN") != true)
    }

    // MARK: - Paper output of individual diagram types

    /// Lays the diagrams out on an A4 page with the real library and returns what `inspection` reports about them.
    private func inspect(_ sources: [String], columnWidth: Int? = nil, _ inspection: String) async throws -> String {
        _ = NSApplication.shared
        let blocks = sources.map {
            let escaped = $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<div class=\"mermaid-block\"><pre class=\"mermaid-source\">\(escaped)</pre></div>"
        }
        let style =
            "<style>body { font-family: 'Hiragino Sans', sans-serif; } .mermaid-source { white-space: pre-wrap; }</style>"
        let column = columnWidth.map { "<div style=\"width: \($0)px\">" + blocks.joined() + "</div>" }
        let result = try await WebPaginator().paginateWithResult(
            .html(style + (column ?? blocks.joined()), baseURL: nil), pageSize: CGSize(width: 595, height: 842),
            margins: .uniform(millimeters: 15), allowsJavaScript: false, preparationScript: inspection,
            rendersMermaid: true)
        return try #require(result.preparationResult)
    }

    @Test("ジャーニー図は原文の枠ではなくSVGの図になる", .timeLimit(.minutes(1)))
    func journeyDraws() async throws {
        let journey = """
            journey
              title 冊子を初めて刷る
              section 準備
                ファイルを開く: 4: 読者
                用紙を選ぶ: 3: 読者, 編集者
            """
        let json = try await inspect(
            [journey],
            """
            return JSON.stringify({
              svg: document.querySelectorAll('.mermaid-block > svg').length,
              errors: document.querySelectorAll('.mermaid-error').length,
              labels: Array.from(document.querySelectorAll('.mermaid-block > svg text')).map(t => t.textContent).join(' ')});
            """)
        let values = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(values["svg"] as? Int == 1)
        #expect(values["errors"] as? Int == 0)
        #expect((values["labels"] as? String)?.contains("用紙を選ぶ") == true)
    }

    @Test("ガントチャートは段の幅で描かれ、日付のラベルが重ならない", .timeLimit(.minutes(1)))
    func ganttUsesColumnWidth() async throws {
        let gantt = """
            gantt
              dateFormat YYYY-MM-DD
              axisFormat %m/%d
              section 原稿
              集める :a1, 2027-01-04, 5d
              書く :a2, after a1, 8d
              section 組版
              組む :b1, after a2, 9d
              刷る :b2, after b1, 6d
            """
        let json = try await inspect(
            [gantt],
            """
            const block = document.querySelector('.mermaid-block');
            const svg = block.querySelector(':scope > svg');
            const labels = Array.from(svg.querySelectorAll('.tick text')).filter(t => t.getClientRects().length)
              .map(t => t.getBoundingClientRect());
            return JSON.stringify({
              width: svg.getBoundingClientRect().width, column: block.getBoundingClientRect().width,
              labels: labels.length,
              overlaps: labels.filter((box, i) => i > 0 && box.left < labels[i - 1].right).length});
            """)
        let values = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double])
        let width = try #require(values["width"])
        let column = try #require(values["column"])
        #expect(abs(width - column) < 2)
        #expect(try #require(values["labels"]) >= 3)
        #expect(values["overlaps"] == 0)
    }

    @Test("ガントチャートの日付が2つだけで重なるときは1つだけ残す", .timeLimit(.minutes(1)))
    func ganttKeepsOneOfTwoOverlappingLabels() async throws {
        // A week between two ticks in a narrow column, with labels wider than the gap between them.
        let gantt = """
            gantt
              dateFormat YYYY-MM-DD
              axisFormat %Y年%m月%d日 %A
              tickInterval 1week
              weekday monday
              section 原稿
              書く :a1, 2027-01-04, 8d
            """
        let json = try await inspect(
            [gantt], columnWidth: 220,
            """
            const labels = Array.from(document.querySelectorAll('.mermaid-block > svg .tick text'));
            const shown = labels.filter(t => t.getClientRects().length).map(t => t.getBoundingClientRect());
            return JSON.stringify({
              labels: labels.length, shown: shown.length,
              overlaps: shown.filter((box, i) => i > 0 && box.left < shown[i - 1].right).length});
            """)
        let values = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Int])
        #expect(values["labels"] == 2)
        #expect(values["shown"] == 1)
        #expect(values["overlaps"] == 0)
    }

    @Test("文書の初期化指示とfront matterは、アプリが決めた設定・配色・CSSを変えられない", .timeLimit(.minutes(1)))
    func documentsCannotOverrideLockedSettings() async throws {
        let red = "#ff0000"
        let sources = [
            """
            %%{init: {"securityLevel": "loose", "htmlLabels": true, "journey": {"textPlacement": "fo"}, \
            "themeCSS": "text { fill: \(red); }", "themeVariables": {"cScale0": "\(red)", "fillType0": "\(red)"}}}%%
            journey
              section 準備
                開く: 4: 読者
            """,
            """
            ---
            config:
              securityLevel: loose
              themeCSS: "text { fill: \(red); } rect, path { fill: \(red); }"
              themeVariables:
                cScale0: "\(red)"
                cScale1: "\(red)"
              journey:
                textPlacement: fo
            ---
            mindmap
              root((冊子))
                読者
                内容
            """,
            """
            %%{init: {"c4": {"person_bg_color": "\(red)", "system_bg_color": "\(red)"}}}%%
            C4Context
              Person(reader, "Reader", "Reads records")
              System(archive, "Archive", "Catalogue")
              Rel(reader, archive, "Finds")
            """,
            """
            ---
            config:
              htmlLabels: true
              flowchart:
                htmlLabels: true
            ---
            flowchart LR
              A[受付] --> B[完了]
            """,
        ]
        let json = try await inspect(
            sources,
            """
            const svgs = Array.from(document.querySelectorAll('.mermaid-block > svg'));
            const painted = svgs.flatMap(svg => Array.from(svg.querySelectorAll('*')))
              .flatMap(el => { const css = getComputedStyle(el); return [css.fill, css.stroke, css.color]; });
            return JSON.stringify({
              drawn: svgs.length, errors: document.querySelectorAll('.mermaid-error').length,
              foreignObjects: document.querySelectorAll('.mermaid-block foreignObject').length,
              red: painted.filter(value => value === 'rgb(255, 0, 0)').length});
            """)
        let values = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Int])
        #expect(values["drawn"] == 4)
        #expect(values["errors"] == 0)
        #expect(values["foreignObjects"] == 0)
        #expect(values["red"] == 0)
    }

    @Test("フローチャートの日本語8字のラベルは1行に収まる", .timeLimit(.minutes(1)))
    func shortJapaneseLabelStaysOnOneLine() async throws {
        let json = try await inspect(
            ["flowchart LR\n  A[受付で原稿を確認] --> B[完了]"],
            """
            const label = Array.from(document.querySelectorAll('.mermaid-block > svg text'))
              .find(text => text.textContent.includes('受付'));
            return String(label.querySelectorAll('.text-outer-tspan').length);
            """)
        #expect(json == "1")
    }

    @Test("代表的な図のどの種類でも、ラベルが描かれ、文字と地のコントラストが4.5対1以上になる", .timeLimit(.minutes(1)))
    func everyDiagramTypeIsReadable() async throws {
        let json = try await inspect(Self.everyType.map(\.source), Self.contrastInspection)
        let reports = try JSONDecoder().decode([ContrastReport].self, from: Data(json.utf8))
        #expect(reports.count == Self.everyType.count)
        for (report, type) in zip(reports, Self.everyType) {
            #expect(report.drawn, "\(type.name) が図にならない")
            #expect(report.text.contains(type.label), "\(type.name) に「\(type.label)」がない")
            #expect(report.checked > 0, "\(type.name) の文字を1つも確かめていない")
            #expect(report.unverified.isEmpty, "\(type.name) で確かめられない文字: \(report.unverified)")
            #expect(report.unreadable.isEmpty, "\(type.name): \(report.unreadable)")
        }
    }

    @Test("コントラストの検査は透明なグループとtspanを読めないと数え、グラデーションの地は確かめられないと数える", .timeLimit(.minutes(1)))
    func contrastInspectionSeesThroughOpacity() async throws {
        _ = NSApplication.shared
        let svgs = [
            "<g opacity=\"0.1\"><text x=\"10\" y=\"20\" fill=\"#000\">faint group</text></g>",
            "<text x=\"10\" y=\"20\" fill=\"#000\"><tspan fill-opacity=\"0.1\">faint tspan</tspan></text>",
            "<defs><linearGradient id=\"g\"><stop offset=\"0\" stop-color=\"#000\"/></linearGradient></defs>"
                + "<rect width=\"200\" height=\"40\" fill=\"url(#g)\"/><text x=\"10\" y=\"20\" fill=\"#fff\">on gradient</text>",
            "<rect width=\"200\" height=\"40\" fill=\"#eee\"/>",
        ].map {
            "<div class=\"mermaid-block\"><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"200\" height=\"40\">\($0)</svg></div>"
        }
        let result = try await WebPaginator().paginateWithResult(
            .html(svgs.joined(), baseURL: nil), pageSize: CGSize(width: 595, height: 842),
            margins: .uniform(millimeters: 15), allowsJavaScript: false, preparationScript: Self.contrastInspection)
        let reports = try JSONDecoder().decode(
            [ContrastReport].self, from: Data(try #require(result.preparationResult).utf8))
        #expect(reports.map(\.unreadable.count) == [1, 1, 0, 0])
        #expect(reports.map(\.unverified) == [[], [], ["on gradient"], []])
        #expect(reports.map(\.checked) == [1, 1, 0, 0])
    }

    @Test("NotebookのMarkdownセルのMermaidは図になる", .timeLimit(.minutes(1)))
    func notebookMarkdownCellDiagram() async throws {
        _ = NSApplication.shared
        let cell = ["```mermaid\n", "flowchart LR\n", "  A[受付] --> B[完了]\n", "```\n"]
        let notebook: [String: Any] = [
            "cells": [["cell_type": "markdown", "metadata": [String: Any](), "source": cell]],
            "metadata": [String: Any](), "nbformat": 4, "nbformat_minor": 5,
        ]
        let data = try JSONSerialization.data(withJSONObject: notebook)
        let paginator = WebPaginator()
        var diagrams: [String] = []
        let renderer = DocumentRenderer(paginateWithResult: { request in
            let inspection = """
                const result = await (async () => { \(request.preparationScript ?? "") })();
                return JSON.stringify({result, diagrams: document.querySelectorAll('.mermaid-block > svg').length});
                """
            let result = try await paginator.paginateWithResult(
                request.source, pageSize: request.pageSize, margins: request.margins,
                allowsJavaScript: request.allowsJavaScript, preparationScript: inspection,
                readsPageRules: request.readsPageRules, drawsBackground: request.drawsBackground,
                rendersMermaid: request.rendersMermaid)
            let json = try #require(result.preparationResult)
            let values = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            diagrams.append(String(describing: values["diagrams"] ?? "nil"))
            return WebPaginator.Result(document: result.document, preparationResult: values["result"] as? String)
        })
        let result = try await renderer.render(DocumentSource(data: data, format: .notebook), settings: settings)
        #expect(diagrams.first == "1")
        #expect(!result.issues.contains { $0.kind == .mermaid })
    }

    private struct ContrastReport: Decodable {
        let drawn: Bool
        let text: String
        /// Labels whose ink and ground could both be worked out.
        let checked: Int
        /// Labels painted with something this check cannot read (a gradient or pattern fill), in itself or below it.
        let unverified: [String]
        let unreadable: [String]
    }

    /// For every label, the ground is what is painted under its middle: the fills, earlier in paint order, that
    /// contain that point, laid over white paper. Opacity is multiplied down from every ancestor group, which matches
    /// the drawing when the label and its ground are not inside the same translucent group. Labels on a marker
    /// (sequence numbers) cannot be seen this way and are left out.
    private static let contrastInspection = """
        const parse = value => {
          const match = /rgba?\\(([^)]+)\\)/.exec(value || '');
          if (!match) return null;
          const parts = match[1].split(/[ ,/]+/).filter(Boolean).map(Number);
          return {r: parts[0], g: parts[1], b: parts[2], a: parts.length > 3 ? parts[3] : 1};
        };
        const over = (top, bottom) => ({r: top.r * top.a + bottom.r * (1 - top.a),
          g: top.g * top.a + bottom.g * (1 - top.a), b: top.b * top.a + bottom.b * (1 - top.a), a: 1});
        const luminance = c => {
          const channel = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; };
          return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
        };
        const ratio = (a, b) => {
          const [x, y] = [luminance(a), luminance(b)];
          return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
        };
        // fill-opacity is inherited, so the element's own value already holds its ancestors'; opacity is not.
        const painted = (el, svg, color) => {
          let alpha = color.a * Number(getComputedStyle(el).fillOpacity);
          for (let node = el; node && node !== svg.parentElement; node = node.parentElement) {
            alpha *= Number(getComputedStyle(node).opacity);
          }
          return {...color, a: alpha};
        };
        // The ground under a label, or null when something below it is painted with a fill this cannot read.
        function ground(svg, text) {
          const box = text.getBoundingClientRect();
          const point = new DOMPoint(box.left + box.width / 2, box.top + box.height / 2);
          let color = {r: 255, g: 255, b: 255, a: 1};
          for (const el of svg.querySelectorAll('rect,circle,ellipse,path,polygon,polyline')) {
            if (!(el.compareDocumentPosition(text) & Node.DOCUMENT_POSITION_FOLLOWING)) break;
            if (!el.getClientRects().length || el.closest('clipPath,defs,mask,marker,pattern,symbol')) continue;
            const css = getComputedStyle(el);
            if (css.visibility === 'hidden' || css.fill === 'none') continue;
            const matrix = el.getScreenCTM();
            if (!matrix || !el.isPointInFill(point.matrixTransform(matrix.inverse()))) continue;
            const fill = parse(css.fill);
            if (!fill) return null;
            color = over(painted(el, svg, fill), color);
          }
          return color;
        }
        return JSON.stringify(Array.from(document.querySelectorAll('.mermaid-block')).map(block => {
          const svg = block.querySelector(':scope > svg');
          if (!svg) return {drawn: false, text: '', checked: 0, unverified: [], unreadable: []};
          let checked = 0;
          const unverified = [];
          const unreadable = [];
          for (const text of svg.querySelectorAll('text, tspan')) {
            if (text.querySelector('tspan') || text.closest('.sequenceNumber')) continue;
            if (!text.textContent.trim() || !text.getClientRects().length) continue;
            const fill = parse(getComputedStyle(text).fill);
            const back = fill && ground(svg, text);
            if (!back) {
              unverified.push(text.textContent.trim());
              continue;
            }
            checked++;
            const value = ratio(over(painted(text, svg, fill), back), back);
            if (value < 4.5) unreadable.push(text.textContent.trim() + ' ' + value.toFixed(2));
          }
          return {drawn: true, text: svg.textContent, checked, unverified, unreadable};
        }));
        """

    /// One small diagram of each kind the bundled library draws without HTML labels (eventmodeling always needs them),
    /// with a word that its drawing must show.
    private static let everyType: [(name: String, label: String, source: String)] = [
        ("flowchart", "原稿", ["flowchart TD", "  A[原稿] --> B{確認}", "  B -->|はい| C[組版]", "  B -->|いいえ| A"]),
        (
            "sequence", "読者",
            [
                "sequenceDiagram", "  autonumber", "  actor R as 読者", "  participant V as ビューア",
                "  R->>V: 開く", "  V-->>R: 紙面", "  Note over R,V: 確かめる",
            ]
        ),
        (
            "class", "Record",
            [
                "classDiagram", "  class Record {", "    +String title", "    +print()", "  }",
                "  Record --> Page : has",
            ]
        ),
        ("state", "Draft", ["stateDiagram-v2", "  [*] --> Draft", "  Draft --> Review : 依頼", "  Review --> [*]"]),
        ("er", "READER", ["erDiagram", "  READER ||--o{ LOAN : makes", "  LOAN {", "    string id PK", "  }"]),
        (
            "requirement", "readable",
            [
                "requirementDiagram", "  requirement readable {", "    id: R01",
                "    text: Paper stays clear", "    risk: medium", "    verifymethod: test", "  }", "  element trial {",
                "    type: \"test\"", "  }", "  trial - verifies -> readable",
            ]
        ),
        (
            "c4", "Archive",
            [
                "C4Context", "  Person(reader, \"Reader\", \"Reads records\")",
                "  System(archive, \"Archive\", \"Catalogue\")", "  System_Ext(store, \"Storage\", \"Keeps sources\")",
                "  Rel(reader, archive, \"Finds\")", "  Rel(archive, store, \"Reads\")",
            ]
        ),
        (
            "architecture", "Source",
            [
                "architecture-beta", "  group local(cloud)[Workspace]",
                "  service source(disk)[Source] in local", "  service reader(server)[Reader] in local",
                "  source:R --> L:reader",
            ]
        ),
        ("block", "Body", ["block-beta", "  columns 2", "  a[\"Title\"]:2", "  b[\"Body\"] c[\"Notes\"]"]),
        (
            "gantt", "書く",
            [
                "gantt", "  dateFormat YYYY-MM-DD", "  section 原稿", "  書く :a1, 2027-01-04, 5d",
                "  組む :crit, a2, after a1, 3d",
            ]
        ),
        (
            "timeline", "初版",
            [
                "timeline", "  title 経緯", "  section 準備", "    一月 : 方針 : 番号", "    二月 : 選定", "  section 公開",
                "    三月 : 初版", "    四月 : 改訂", "    五月 : 保存", "    六月 : 点検",
            ]
        ),
        ("journey", "選ぶ", ["journey", "  section 準備", "    開く: 4: 読者", "  section 確認", "    選ぶ: 3: 読者, 編集者"]),
        (
            "mindmap", "冊子",
            [
                "mindmap", "  root((冊子))", "    読者", "      目的", "    内容", "      章", "    用紙", "      判型",
                "    品質", "      校正", "    綴じ", "      向き", "    配布", "      部数",
            ]
        ),
        (
            "kanban", "図を描く",
            [
                "kanban", "  a[受付]", "    a1[一覧を確かめる]", "  b[作業中]", "    b1[図を描く]", "  c[確認]", "    c1[校正]",
                "  d[完了]", "    d1[番号を振る]",
            ]
        ),
        (
            "gitGraph", "fix",
            [
                "gitGraph", "  commit id: \"1\"", "  branch fix", "  checkout fix", "  commit id: \"2\"",
                "  checkout main", "  merge fix id: \"3\"", "  branch next", "  checkout next", "  commit id: \"4\"",
            ]
        ),
        (
            "swimlane", "受け取る",
            [
                "swimlane-beta TB", "  subgraph 受付", "    A[受け取る]", "  end", "  subgraph 編集", "    B[書く]",
                "  end", "  A --> B",
            ]
        ),
        (
            "agentflow", "Check",
            [
                "agentflow-beta TB", "  input[\"Manuscript\"]@{ shape: input }",
                "  check[\"Check\"]@{ shape: task }", "  input --> check",
            ]
        ),
        (
            "pie", "Photographs",
            [
                "pie showData", "  \"Photographs\" : 240", "  \"Booklets\" : 120", "  \"Maps\" : 60",
                "  \"Letters\" : 100", "  \"Notes\" : 40",
            ]
        ),
        (
            "quadrant", "Plan",
            [
                "quadrantChart", "  x-axis Low --> High", "  y-axis Low --> High", "  quadrant-1 Plan",
                "  quadrant-2 Try", "  quadrant-3 Drop", "  quadrant-4 Limit", "  Captions: [0.2, 0.8]",
            ]
        ),
        ("sankey", "Intake", ["sankey-beta", "Intake,Reviewed,600", "Reviewed,Public,360", "Reviewed,Pending,240"]),
        (
            "xychart", "Feb",
            [
                "xychart-beta", "  x-axis [Jan, Feb, Mar]", "  y-axis \"Records\" 0 --> 80",
                "  bar [24, 41, 68]", "  line [30, 40, 70]",
            ]
        ),
        (
            "radar", "Content",
            [
                "radar-beta", "  axis a[\"Content\"], b[\"Figures\"], c[\"Paper\"]",
                "  curve first[\"First\"]{4,3,4}", "  curve second[\"Second\"]{5,4,5}", "  max 5", "  min 0",
            ]
        ),
        (
            "treemap", "Masters",
            [
                "treemap-beta", "  \"Images\"", "    \"Masters\": 240", "    \"Copies\": 120", "  \"Texts\"",
                "    \"Booklets\": 100", "  \"Metadata\"", "    \"Catalogue\": 35",
            ]
        ),
        (
            "venn", "Evidence",
            [
                "venn-beta", "  set A[\"Content\"]", "  set B[\"Evidence\"]", "  set C[\"Paper\"]",
                "  union A,B[\"Supported\"]",
            ]
        ),
        (
            "ishikawa", "Layout",
            [
                "ishikawa", "  Unreadable proof", "  Content", "    Undefined terms", "  Layout",
                "    Narrow columns",
            ]
        ),
        (
            "wardley", "Storage",
            [
                "wardley-beta", "  anchor Reader [0.95, 0.7]", "  component Copy [0.6, 0.5]",
                "  component Storage [0.2, 0.9]", "  Reader -> Copy", "  Copy -> Storage",
            ]
        ),
        (
            "cynefin", "typo",
            [
                "cynefin-beta", "  complex", "    \"New needs\"", "  clear", "    \"Known typo\"",
                "  complex --> clear : \"Pattern\"",
            ]
        ),
        ("packet", "Flags", ["packet-beta", "  0-7: \"Version\"", "  8-15: \"Flags\"", "  16-31: \"Count\""]),
        ("treeView", "notes.md", ["treeView-beta", "  project/", "    notes.md", "    figures/", "      map.svg"]),
        (
            "railroad", "prefix",
            [
                "railroad-ebnf-beta", "  record = prefix \"-\" digit ;", "  prefix = \"SM\" | \"AR\" ;",
                "  digit = \"0\" | \"1\" ;",
            ]
        ),
    ].map { ($0.0, $0.1, $0.2.joined(separator: "\n")) }
}
