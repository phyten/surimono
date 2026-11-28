import Foundation
import WebKit

@MainActor
enum MermaidScript {
    // Cache the bytes in the host, but evaluate them only once in each document that actually has diagrams.
    static let library = Bundle.module.url(forResource: "mermaid.min", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// The preparation runs as the body of an async function, where the bundle's top-level `var` would stay local
    /// while its last line reads the namespace from `globalThis`; binding both to one object keeps the file unchanged.
    static func loading(_ library: String) -> String {
        """
        "use strict";
        var __esbuild_esm_mermaid_nm = globalThis.__esbuild_esm_mermaid_nm = globalThis.__esbuild_esm_mermaid_nm || {};
        \(library)
        ;return typeof globalThis.mermaid?.render;
        """
    }

    static let probe = "return String(document.querySelectorAll('.mermaid-block > .mermaid-source').length);"

    private static var offlineRules: WKContentRuleList?

    static func preventResourceLoads(in webView: WKWebView) async throws {
        if offlineRules == nil {
            offlineRules = try await WebKitReply<WKContentRuleList>.wait(until: .now + .seconds(15)) { reply in
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "surimono-mermaid-offline",
                    encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
                ) { list, error in
                    if let list {
                        reply(.success(list))
                    } else {
                        reply(.failure(error ?? WebPaginator.PaginationError.printFailed))
                    }
                }
            }
        }
        if let offlineRules { webView.configuration.userContentController.add(offlineRules) }
    }

    static let fallback = """
        for (const source of document.querySelectorAll('.mermaid-block > .mermaid-source')) {
          source.parentElement.classList.add('mermaid-error');
        }
        """

    static func budgetMilliseconds(count: Int) -> Int {
        min(60_000, 10_000 + min(167, max(0, count)) * 300)
    }

    static let maxTextSize = 50000

    /// Pale grounds for the diagram types that colour their parts in turn (timeline, mindmap, kanban, pie, treemap…).
    /// The neutral theme's own scale runs to dark greys under dark labels; these stay light enough for black text
    /// on every one, use little ink, and alternate in lightness so that neighbours stay apart in black and white.
    static let paperScale = [
        "#D0D0D0", "#E4E4E4", "#B8B8B8", "#DCDCDC", "#C4C4C4", "#E8E8E8",
        "#ADADAD", "#D8D8D8", "#C9C9C9", "#E0E0E0", "#BDBDBD", "#E6E6E6",
    ]

    /// Bars, lines and points of an xychart, in plot order: a mid grey for the usual first bar series, then a dark line.
    static let plotPalette = ["#A3A3A3", "#3D3D3D", "#CFCFCF", "#6E6E6E", "#8A8A8A", "#262626", "#BDBDBD", "#555555"]

    static let branchColors = ["#999999", "#BBBBBB", "#8C8C8C", "#CCCCCC", "#A6A6A6", "#B3B3B3", "#C4C4C4", "#ADADAD"]
    static let setInks = ["#555555", "#3D3D3D", "#666666", "#4D4D4D", "#5E5E5E", "#444444", "#6B6B6B", "#595959"]

    static var themeVariables: String {
        // Gantt prints white on its critical bars; the neutral red is too light for it.
        var entries = ["scaleLabelColor: '#222222'", "critBkgColor: '#B8321A'"]
        for (index, color) in paperScale.enumerated() {
            entries.append("cScale\(index): '\(color)'")
            entries.append("cScaleLabel\(index): '#222222'")
        }
        // gitGraph and venn derive their colours from the scale; branch lines and set names need more ink than a ground.
        for (index, color) in branchColors.enumerated() {
            entries.append("git\(index): '\(color)'")
            entries.append("gitBranchLabel\(index): '#222222'")
        }
        for (index, color) in setInks.enumerated() { entries.append("venn\(index + 1): '\(color)'") }
        entries.append("xyChart: {plotColorPalette: '\(plotPalette.joined(separator: ","))'}")
        return "{" + entries.joined(separator: ", ") + "}"
    }

    /// C4 draws every box label in white with an inline `!important` that no style sheet can override, and its own
    /// defaults (light blues, light greys) leave that white unreadable. Grey grounds dark enough for white text.
    static var c4Colors: String {
        let grounds = [
            ("person", "#3B3B3B"), ("system", "#474747"), ("container", "#555555"), ("component", "#636363"),
        ]
        let entries = grounds.flatMap { kind, ground in
            ["", "_db", "_queue"].flatMap { suffix in
                ["\(kind)\(suffix)_bg_color: '\(ground)'", "external_\(kind)\(suffix)_bg_color: '#6E6E6E'"]
            }
        }
        return "{" + entries.joined(separator: ", ") + "}"
    }

    /// Journey colours its section and task labels with the same class as their boxes, so with SVG text the label
    /// takes the box's fill and disappears; HTML labels avoided this, but are refused below.
    static let journeyLabels = "text.journey-section, text.task { fill: #222222; }"

    static func rendering(budgetMilliseconds: Int) -> String {
        """
        \(fallback)
        const sources = Array.from(document.querySelectorAll('.mermaid-block > .mermaid-source'));
        const deadline = performance.now() + \(budgetMilliseconds);
        const fontFamily = getComputedStyle(document.body).fontFamily;
        if (typeof mermaid === 'undefined') return;
        // Lock configuration from directives/front matter too: diagrams cannot opt into HTML, CSS or web fonts.
        // Journey labels default to foreignObject, which the checks below refuse; flowchart's default wrapping width
        // breaks eight Japanese characters onto two lines.
        mermaid.initialize({
          startOnLoad: false, theme: 'neutral', securityLevel: 'strict', fontFamily,
          themeVariables: \(themeVariables), themeCSS: '\(journeyLabels)', c4: \(c4Colors),
          htmlLabels: false, flowchart: {htmlLabels: false, wrappingWidth: 200}, journey: {textPlacement: 'tspan'},
          suppressErrorRendering: true, deterministicIds: true, maxTextSize: \(maxTextSize), maxEdges: 500,
          secure: [...Object.keys(mermaid.mermaidAPI.defaultConfig), 'htmlLabels', 'themeCSS', 'fontFamily', 'flowchart']
        });
        for (const source of sources) source.parentElement.classList.add('mermaid-timeout');
        let stopped = false;
        for (const [index, source] of sources.entries()) {
          const block = source.parentElement;
          const remaining = deadline - performance.now();
          if (stopped || remaining <= 0) continue;
          // Over the limit, the library draws a placeholder diagram instead of throwing; keep the source instead.
          if (source.textContent.length > \(maxTextSize)) {
            block.classList.remove('mermaid-timeout');
            continue;
          }
          const staging = document.createElement('div');
          // Layout needs a connected element; keep unfinished work out of the printed flow.
          staging.style.cssText = 'position:absolute;left:-100000px;top:0;visibility:hidden';
          // Diagrams that fill their container (gantt) would otherwise lay out in a few hundred pixels.
          const blockStyle = getComputedStyle(block);
          const columnWidth = block.clientWidth - parseFloat(blockStyle.paddingLeft) - parseFloat(blockStyle.paddingRight);
          if (columnWidth > 0) staging.style.width = columnWidth + 'px';
          document.body.appendChild(staging);
          let timer;
          try {
            const result = await Promise.race([
              mermaid.render('surimono-mermaid-' + index, source.textContent, staging),
              new Promise((_, reject) => { timer = setTimeout(() => {
                stopped = true;
                reject(new Error('timeout'));
              }, remaining); })
            ]);
            const parsed = new DOMParser().parseFromString(result.svg, 'image/svg+xml');
            const svg = parsed.documentElement;
            if (svg.localName !== 'svg' || parsed.querySelector('parsererror')) throw new Error('svg');
            // Keep the result static and local, even for diagram types that accept image or link syntax.
            // A diagram whose labels need HTML (math labels use foreignObject even without htmlLabels) or images
            // would lose content once those parts are removed, so it fails as a whole and keeps its source.
            if (svg.querySelector('script,foreignObject,image')) throw new Error('unsupported');
            for (const node of svg.querySelectorAll('a')) node.replaceWith(...node.childNodes);
            const width = svg.viewBox.baseVal.width;
            if (width > 0) svg.style.width = width + 'px';
            svg.style.maxWidth = '100%';
            svg.style.height = 'auto';
            const rendered = document.importNode(svg, true);
            block.replaceChildren(rendered);
            // Gantt lets d3 choose its date ticks regardless of label width; keep every n-th label so none overlap,
            // down to the first label alone. Measured once, with every label shown, then hidden once.
            if (rendered.getAttribute('aria-roledescription') === 'gantt') {
              for (const axis of rendered.querySelectorAll('g.grid')) {
                const labels = Array.from(axis.querySelectorAll('.tick text'));
                const boxes = labels.map(label => label.getBoundingClientRect());
                let step = 1;
                while (step < labels.length && !boxes.every((box, i) =>
                  i % step || i < step || box.left >= boxes[i - step].right)) step++;
                labels.forEach((label, i) => { if (i % step) label.style.display = 'none'; });
              }
            }
            globalThis.surimonoRenderedDiagrams?.add(rendered);
            block.classList.remove('mermaid-error', 'mermaid-timeout');
          } catch (error) {
            // Syntax failures keep their individual diagnostics; a diagram that parsed but needs HTML or images says
            // so, since checking its syntax would not help.
            if (!stopped) block.classList.remove('mermaid-timeout');
            if (error?.message === 'unsupported') block.classList.add('mermaid-unsupported');
          } finally {
            clearTimeout(timer);
            staging.remove();
          }
        }
        """
    }
}
