import AppKit
import SurimonoCore
import SurimonoRendering
import Testing

@testable import Surimono

/// Clipboard and service text through the format detector: what opens without asking, the question, and opening the
/// same text again as another format.
@MainActor
@Suite(.serialized)
struct ClipboardQuestionFlowTests {
    /// Markdown the detector opens without asking.
    private static let markdown = "# Title\n\nSome **bold** text.\n\n## Section\n\n- one\n- two\n- three\n"
    /// A single heading: Markdown is possible but not confirmed, so the reader is asked.
    private static let unsure = "# 見出し"

    @MainActor private final class Fixture {
        let suite = TestDefaultsSuite()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard(name: .init("SurimonoTests.question.\(UUID().uuidString)"))
        let windows: ClipboardWindows
        let presentation: ClipboardWindowFixture
        let preferences: AppPreferences
        var questions: [(ClipboardQuestion, ClipboardTextSource, NSWindow?)] = []
        var pending: ((ClipboardTextKind?) -> Void)?
        /// The answer given at once, or nil to leave the question open in `pending`.
        var answer: ClipboardTextKind??
        var forwarded = 0
        private var panels: [NSWindow] = []

        init(answer: ClipboardTextKind?? = nil, ordered: Bool = false) {
            self.answer = answer
            preferences = AppPreferences(defaults: suite.defaults)
            windows = ClipboardWindows(
                openFiles: { _, _, _ in Issue.record("ファイルは開かない") }, warn: { _ in Issue.record("警告しない") },
                closeWelcome: {})
            presentation = ClipboardWindowFixture(windows, ordered: ordered)
            windows.preferences = preferences
            windows.library = UserLibrary(root: directory.appendingPathComponent("Library"))
            windows.ask = { [unowned self] question, source, window, completion in
                questions.append((question, source, window))
                // The property, not the initializer's argument: tests change their answer as they go.
                if let answer = self.answer { completion(answer) } else { pending = completion }
            }
            windows.showQuestion = { [unowned self] in forwarded += 1 }
        }

        func copy(_ text: String) {
            board.clearContents()
            board.setString(text, forType: .string)
        }

        func present(
            _ question: ClipboardQuestion, over parent: NSWindow?, completion: @escaping (ClipboardTextKind?) -> Void
        ) throws -> NSWindow {
            ClipboardQuestionPanel.present(question, source: .clipboard, over: parent, completion: completion)
            let panel = try #require(ClipboardQuestionPanel.window)
            panel.alphaValue = 0
            panels.append(panel)
            return panel
        }

        func cleanUp() {
            for panel in panels where panel.isVisible {
                panel.sheetParent?.endSheet(panel)
                panel.close()
            }
            presentation.close()
            board.releaseGlobally()
            suite.remove()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("URL の型が文字と同じときと、表計算のタブ区切りの型があるときだけ手がかりにする")
    func hints() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let board = fixture.board
        board.clearContents()
        board.setString(" https://example.com/a\n", forType: .string)
        board.setString("https://example.com/a", forType: .URL)
        #expect(ClipboardWindows.hints(for: " https://example.com/a\n", in: board) == .init(hasMatchingURL: true))
        board.clearContents()
        board.setString("https://example.com/a", forType: .string)
        board.setString("https://example.com/b", forType: .URL)
        #expect(ClipboardWindows.hints(for: "https://example.com/a", in: board) == .init())
        board.clearContents()
        board.setString("a\tb\n1\t2", forType: .string)
        board.setString("a\tb\n1\t2", forType: .tabularText)
        #expect(
            ClipboardWindows.content(from: board) == .text("a\tb\n1\t2", hints: .init(hasTabularData: true)))
        board.clearContents()
        board.setString("見えていた文字", forType: .string)
        board.setString("<p>見えていた文字</p>", forType: .html)
        #expect(ClipboardWindows.content(from: board) == .text("見えていた文字", hints: .init()))
    }

    @Test("確かな Markdown は聞かずに Markdown で開き、自動で決めたと覚える", .timeLimit(.minutes(1)))
    func confidentOpensWithoutAsking() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.copy(Self.markdown)
        let controller = try #require(fixture.windows.open(from: fixture.board, window: nil))
        #expect(fixture.questions.isEmpty)
        let model = try #require(controller.model)
        #expect(model.format == .markdown)
        #expect(model.textFormatOrigin == .automatic)
        #expect(model.textKind == .markdown)
        #expect(model.memoryContent == Data(Self.markdown.utf8))
    }

    @Test("迷う文字は質問に答えた形式で開き、手で選んだと覚える", .timeLimit(.minutes(1)))
    func unsureAsks() throws {
        let fixture = Fixture(answer: .some(.org))
        defer { fixture.cleanUp() }
        fixture.copy(Self.unsure)
        let controller = try #require(fixture.windows.open(from: fixture.board, window: nil))
        let (question, source, window) = try #require(fixture.questions.first)
        #expect(fixture.questions.count == 1)
        #expect(source == .clipboard)
        #expect(window == nil)
        #expect(question.preferred == .plainText)
        #expect(question.options.map(\.kind).contains(.markdown))
        let model = try #require(controller.model)
        #expect(model.format == .org)
        #expect(model.textFormatOrigin == .chosen)
        #expect(!fixture.windows.isAsking)
    }

    @Test("質問を取り消すと何も開かない")
    func cancelOpensNothing() {
        let fixture = Fixture(answer: .some(nil))
        defer { fixture.cleanUp() }
        fixture.copy(Self.unsure)
        #expect(fixture.windows.open(from: fixture.board, window: nil) == nil)
        #expect(fixture.questions.count == 1)
        #expect(!fixture.windows.hasWindows)
        #expect(!fixture.windows.isAsking)
    }

    @Test("印刷画面で開く要求は、質問に答えたあとも印刷画面へ届く", .timeLimit(.minutes(1)))
    func printingSurvivesTheQuestion() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.copy(Self.unsure)
        #expect(fixture.windows.open(from: fixture.board, window: nil, printing: true) == nil)
        #expect(!fixture.windows.hasWindows)
        let answer = try #require(fixture.pending)
        answer(.markdown)
        let controller = try #require(fixture.windows.open(from: fixture.board, window: nil))
        let model = try #require(controller.model)
        #expect(model.format == .markdown)
        #expect(model.isPrintModeRequested || model.mode == .print)
    }

    @Test("質問が出ている間にもう一度呼ばれても質問を重ねず、出ている質問を前に出す")
    func oneQuestionAtATime() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.copy(Self.unsure)
        fixture.windows.open(from: fixture.board, window: nil)
        fixture.copy("* **First**\n* **Second**\n* **Third**")
        #expect(fixture.windows.open(from: fixture.board, window: nil, printing: true) == nil)
        #expect(fixture.questions.count == 1)
        #expect(fixture.forwarded == 1)
        let answer = try #require(fixture.pending)
        answer(nil)
        #expect(!fixture.windows.isAsking)
    }

    @Test("同じ文字の窓が開いていれば、聞かずにその窓を前に出す", .timeLimit(.minutes(1)))
    func sameTextIsNotAskedAgain() throws {
        let fixture = Fixture(answer: .some(.markdown))
        defer { fixture.cleanUp() }
        fixture.copy(Self.unsure)
        let first = try #require(fixture.windows.open(from: fixture.board, window: nil))
        let second = try #require(fixture.windows.open(from: fixture.board, window: nil))
        #expect(first === second)
        #expect(fixture.questions.count == 1)
    }

    @Test("迷ったらテキストで開く設定では、聞かずにテキストで開く", .timeLimit(.minutes(1)))
    func plainTextWhenUnsure() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.preferences.clipboardFormat.mode = .plainTextWhenUnsure
        fixture.copy(Self.unsure)
        let controller = try #require(fixture.windows.open(from: fixture.board, window: nil))
        #expect(fixture.questions.isEmpty)
        let model = try #require(controller.model)
        #expect(model.format == .plainText)
        #expect(model.textFormatOrigin == .automatic)
    }

    @Test("毎回聞く設定では、確かな Markdown でも聞く")
    func alwaysAsk() {
        let fixture = Fixture(answer: .some(nil))
        defer { fixture.cleanUp() }
        fixture.preferences.clipboardFormat.mode = .alwaysAsk
        fixture.copy(Self.markdown)
        #expect(fixture.windows.open(from: fixture.board, window: nil) == nil)
        #expect(fixture.questions.count == 1)
        #expect(fixture.questions.first?.0.reason == .alwaysAsk)
    }

    @Test("いつも同じ形式で開く設定では、その形式で聞かずに開き、設定で決めたと覚える", .timeLimit(.minutes(1)))
    func fixedFormat() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.preferences.clipboardFormat.mode = .fixed
        fixture.preferences.clipboardFormat.fixedKind = .org
        fixture.copy(Self.markdown)
        let controller = try #require(fixture.windows.open(from: fixture.board, window: nil))
        #expect(fixture.questions.isEmpty)
        let model = try #require(controller.model)
        #expect(model.format == .org)
        #expect(model.textFormatOrigin == .settings)
    }

    @Test("自動の判定から外した形式は、確かでも自動では開かず、質問では選べる", .timeLimit(.minutes(1)))
    func disabledKind() throws {
        let fixture = Fixture(answer: .some(nil))
        defer { fixture.cleanUp() }
        fixture.preferences.clipboardFormat.automaticKinds.remove(.markdown)
        fixture.copy(Self.markdown)
        let opened = fixture.windows.open(from: fixture.board, window: nil)
        #expect(opened?.model?.format != .markdown)
        opened?.window?.close()
        fixture.answer = .some(.markdown)
        fixture.preferences.clipboardFormat.mode = .alwaysAsk
        fixture.copy(Self.markdown + "\nMore.\n")
        let chosen = try #require(fixture.windows.open(from: fixture.board, window: nil))
        let question = try #require(fixture.questions.last?.0)
        #expect((question.options + question.others).contains { $0.kind == .markdown })
        let chosenModel = try #require(chosen.model)
        #expect(chosenModel.format == .markdown)
    }

    @Test("URL と判定された文字はテキストで開く", .timeLimit(.minutes(1)))
    func urlOpensAsText() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.board.clearContents()
        fixture.board.setString("https://example.com/page", forType: .string)
        fixture.board.setString("https://example.com/page", forType: .URL)
        let controller = try #require(fixture.windows.open(from: fixture.board, window: nil))
        #expect(fixture.questions.isEmpty)
        let model = try #require(controller.model)
        #expect(model.format == .plainText)
        #expect(model.textKind == .plainText)
    }

    @Test("表計算からのタブ区切りは表として開き、欄に分かれる", .timeLimit(.minutes(1)))
    func tabbedTable() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let text = "name\tqty\tprice\napple\t3\t120\npear\t2\t200\n"
        fixture.board.clearContents()
        fixture.board.setString(text, forType: .string)
        fixture.board.setString(text, forType: .tabularText)
        let controller = try #require(fixture.windows.open(from: fixture.board, window: nil))
        let model = try #require(controller.model)
        #expect(model.format == .csv)
        let html = try #require(
            DocumentRenderer.structureHTML(of: DocumentSource(data: Data(text.utf8), fileURL: nil, format: .csv)))
        #expect(html.contains("<td>apple</td><td>3</td><td>120</td>"))
        // A file says its delimiter with its extension, as before.
        let file = try #require(
            DocumentRenderer.structureHTML(
                of: DocumentSource(
                    data: Data(text.utf8), fileURL: URL(fileURLWithPath: "/fixtures/table.csv"), format: .csv)))
        #expect(!file.contains("<td>apple</td>"))
    }

    @Test("形式を選び直すと、同じ原文を別の形式で同じ位置の窓に開き直し、判定し直さない", .timeLimit(.minutes(1)))
    func reopenAsAnotherFormat() async throws {
        let fixture = Fixture(ordered: true)
        defer { fixture.cleanUp() }
        fixture.copy(Self.markdown)
        let first = try #require(fixture.windows.open(from: fixture.board, window: nil))
        let firstWindow = try #require(first.window)
        // Away from where a new window would cascade to, and at the top of whatever screen the test runs on: on a
        // small screen a window placed lower is moved up to fit when it is shown, whatever asked for its place.
        let visible = try #require(firstWindow.screen ?? NSScreen.main).visibleFrame
        firstWindow.setFrameTopLeftPoint(NSPoint(x: visible.minX + 37, y: visible.maxY))
        let topLeft = NSPoint(x: firstWindow.frame.minX, y: firstWindow.frame.maxY)
        let firstModel = try #require(first.model)
        firstModel.reopenText(as: .plainText)
        #expect(!firstWindow.isVisible)
        #expect(fixture.preferences.closedClipboardDocuments.entries.isEmpty)
        #expect(fixture.windows.hasWindows)
        let second = try #require(fixture.windows.open(from: fixture.board, window: nil))
        #expect(second !== first)
        #expect(fixture.questions.isEmpty)
        let secondModel = try #require(second.model)
        #expect(secondModel.format == .plainText)
        #expect(secondModel.memoryContent == Data(Self.markdown.utf8))
        #expect(secondModel.textFormatOrigin == .chosen)
        #expect(secondModel.displayName == firstModel.displayName)
        let window = try #require(second.window)
        #expect(NSPoint(x: window.frame.minX, y: window.frame.maxY) == topLeft)
        // The window fits its paper once the pages are laid out, from the same top left.
        for _ in 0..<1500 where !secondModel.hasSizedWindow { try await Task.sleep(for: .milliseconds(20)) }
        #expect(secondModel.hasSizedWindow)
        #expect(abs(window.frame.minX - topLeft.x) < 1)
        #expect(abs(window.frame.maxY - topLeft.y) < 1)
        // Choosing the format it already has does nothing.
        secondModel.reopenText(as: .plainText)
        #expect(try #require(fixture.windows.open(from: fixture.board, window: nil)) === second)
        second.close()
        let restored = try #require(fixture.windows.reopenClosed())
        let restoredModel = try #require(restored.model)
        #expect(restoredModel.textFormatOrigin == .chosen)
        #expect(restoredModel.textKind == .plainText)
        #expect(fixture.questions.isEmpty)
    }

    @Test("「…」のメニューは、クリップボードの文字にだけ形式の選び直しを出す")
    func moreMenuOffersTheFormat() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.copy(Self.markdown)
        let controller = try #require(fixture.windows.open(from: fixture.board, window: nil))
        let model = try #require(controller.model)
        let content = BandMenuContent(model: model)
        let paper = try #require(content.groups.first { $0.id == .paper })
        #expect(paper.entries.first?.id == .textFormat)
        #expect(content.entry(.textFormat).value == String(format: String(localized: "%@ (Automatic)"), "Markdown"))
        let file = DocumentViewModel(
            data: Data(Self.markdown.utf8), fileURL: URL(fileURLWithPath: "/fixtures/a.md"), format: .markdown,
            preferences: fixture.preferences, library: UserLibrary(root: fixture.directory))
        defer { file.stop() }
        #expect(file.textKind == nil)
        #expect(!BandMenuContent(model: file).groups.flatMap(\.entries).contains { $0.id == .textFormat })
        let image = fixture.windows.open(TestFixtures.png(red: 0.3), format: .image, title: "Image")
        let imageModel = try #require(image.model)
        #expect(imageModel.textKind == nil)
    }

    @Test("サービスの文字は同じ判定を通り、選んだ文字として聞かれ、刷る指定が答えのあとも残る", .timeLimit(.minutes(1)))
    func serviceText() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let windows = fixture.windows
        let router = OpenRouter(
            openDocument: { _, _ in Issue.record("文書は開かない") }, openBundle: { _, _ in nil },
            openBinder: { _, _ in nil }, warn: { _ in Issue.record("警告しない") }, hasOpenWindows: { false },
            showWelcome: {},
            openText: { text, hints, title, printing in
                windows.open(
                    text: text, hints: hints, title: title ?? "Selected Text", source: .selection, window: nil,
                    printing: printing)
            })
        fixture.copy(Self.unsure)
        var message: NSString?
        ServiceProvider(router: router, activate: {}).printSelection(fixture.board, userData: nil, error: &message)
        #expect(message == nil)
        #expect(fixture.questions.first?.1 == .selection)
        let answer = try #require(fixture.pending)
        answer(.markdown)
        let controller = try #require(windows.open(from: fixture.board, window: nil))
        let model = try #require(controller.model)
        #expect(model.format == .markdown)
        #expect(model.displayName == "Selected Text")
        #expect(model.isPrintModeRequested || model.mode == .print)
    }

    /// The real question as a sheet on a real clipboard window, answered nowhere yet.
    private func presentSheet(
        _ fixture: Fixture, record: @escaping (ClipboardTextKind?) -> Void
    ) throws -> (parent: NSWindow, sheet: NSWindow) {
        fixture.copy(Self.markdown)
        let controller = try #require(fixture.windows.open(from: fixture.board, window: nil))
        let parent = try #require(controller.window)
        let question = ClipboardQuestion(
            text: Self.unsure, detection: ClipboardFormatDetector.detect(Self.unsure), settings: .standard)
        let sheet = try fixture.present(question, over: parent, completion: record)
        try #require(sheet.sheetParent === parent)
        return (parent, sheet)
    }

    private func wait(until condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("質問のシートは親のウインドウが閉じると答えなしで一度だけ終わり、次の質問は新しく出る", .timeLimit(.minutes(1)))
    func sheetFinishesWhenItsParentCloses() async throws {
        let fixture = Fixture(ordered: true)
        defer { fixture.cleanUp() }
        var answers: [ClipboardTextKind?] = []
        let (parent, sheet) = try presentSheet(fixture) { answers.append($0) }
        parent.close()
        try await wait { !answers.isEmpty }
        // Anything the sheet's own ending still delivers would arrive by now.
        try await Task.sleep(for: .milliseconds(100))
        #expect(answers == [nil])
        #expect(ClipboardQuestionPanel.window == nil)
        let question = ClipboardQuestion(
            text: Self.unsure, detection: ClipboardFormatDetector.detect(Self.unsure), settings: .standard)
        let next = try fixture.present(question, over: nil) { answers.append($0) }
        #expect(next !== sheet)
        next.close()
        #expect(answers == [nil, nil])
    }

    @Test("ほかから終えられた質問のシートは答えなしで一度だけ終わり、次の質問は新しく出る", .timeLimit(.minutes(1)))
    func sheetFinishesWhenEndedFromOutside() async throws {
        let fixture = Fixture(ordered: true)
        defer { fixture.cleanUp() }
        var answers: [ClipboardTextKind?] = []
        let (parent, sheet) = try presentSheet(fixture) { answers.append($0) }
        parent.endSheet(sheet)
        try await wait { !answers.isEmpty }
        try await Task.sleep(for: .milliseconds(100))
        #expect(answers == [nil])
        #expect(ClipboardQuestionPanel.window == nil)
        #expect(parent.attachedSheet == nil)
        let question = ClipboardQuestion(
            text: Self.unsure, detection: ClipboardFormatDetector.detect(Self.unsure), settings: .standard)
        let next = try fixture.present(question, over: parent) { answers.append($0) }
        #expect(next !== sheet)
        #expect(next.sheetParent === parent)
        parent.endSheet(next)
        try await wait { answers.count == 2 }
        #expect(answers == [nil, nil])
    }

    @Test("形式の決め方の設定は保存され、読めない値からは標準に戻る")
    func settingsPersist() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.clipboardFormat == .standard)
        preferences.clipboardFormat.mode = .fixed
        preferences.clipboardFormat.fixedKind = .latex
        preferences.clipboardFormat.carefulness = .careful
        preferences.clipboardFormat.automaticKinds.remove(.html)
        let reread = AppPreferences(defaults: suite.defaults).clipboardFormat
        #expect(reread.mode == .fixed)
        #expect(reread.fixedKind == .latex)
        #expect(reread.carefulness == .careful)
        #expect(!reread.automaticKinds.contains(.html))
        #expect(reread.automaticKinds.contains(.markdown))
        suite.defaults.set(Data("not json".utf8), forKey: "clipboardFormat")
        #expect(AppPreferences(defaults: suite.defaults).clipboardFormat == .standard)
        suite.defaults.set(Data(#"{"mode":"someday","carefulness":"eager"}"#.utf8), forKey: "clipboardFormat")
        let partly = AppPreferences(defaults: suite.defaults).clipboardFormat
        #expect(partly.mode == .askWhenUnsure)
        #expect(partly.carefulness == .eager)
    }

    @Test("理由と根拠は判定器のすべての場合に 1 文ずつあり、どの言語でも空でない")
    func everyReasonAndEvidenceHasWords() {
        let evidence: [ClipboardFormatDetection.Evidence] = [
            .headings(2), .lists(2), .codeBlocks(1), .tables(1), .markup(3), .metadata(1), .links(1), .document,
            .pasteboard, .incomplete, .conflictingSyntax, .damagedText,
        ]
        let words = evidence.map { ClipboardFormatText.evidence($0, of: .markdown) }
        #expect(Set(words).count == evidence.count)
        #expect(
            ClipboardFormatText.evidence(.markup(3), of: .latex) != ClipboardFormatText.evidence(.markup(3), of: .html))
        let texts = ["", Self.unsure, "* **First**\n* **Second**\n* **Third**", Self.markdown]
        for text in texts {
            let question = ClipboardQuestion(
                text: text, detection: ClipboardFormatDetector.detect(text), settings: .standard)
            #expect(!ClipboardFormatText.reason(question).isEmpty)
        }
        for kind in ClipboardTextKind.choosable {
            #expect(!ClipboardFormatText.name(kind).isEmpty)
        }
    }

    @Test("整形の度合いの注記は、迷ったときに自分で開く決め方でMarkdownを見分けるときだけ出す")
    func carefulnessNoteOnlyWhenItCanComeTrue() {
        var settings = ClipboardFormatSettings.standard
        #expect(
            ClipboardSettings.carefulnessNote(for: settings)
                == String(localized: "Usually also formats notes of headings, sentences and a list."))
        settings.mode = .plainTextWhenUnsure
        settings.carefulness = .careful
        #expect(
            ClipboardSettings.carefulnessNote(for: settings)
                == String(
                    localized:
                        "Formats less than Standard. A note of headings, sentences and a list may stay unformatted."
                ))
        settings.mode = .alwaysAsk
        #expect(ClipboardSettings.carefulnessNote(for: settings) == nil)
        settings.mode = .fixed
        #expect(ClipboardSettings.carefulnessNote(for: settings) == nil)
        settings.mode = .askWhenUnsure
        settings.automaticKinds.remove(.markdown)
        #expect(ClipboardSettings.carefulnessNote(for: settings) == nil)
    }

    @Test("ほかの形式の記法が混じるとは理由の行だけが言い、候補の根拠の行には出さない")
    func conflictingSyntaxIsSaidOnce() {
        let text = "* **First**\n* **Second**\n* **Third**"
        let question = ClipboardQuestion(
            text: text, detection: ClipboardFormatDetector.detect(text), settings: .standard)
        #expect(question.reason == .conflictingSyntax)
        #expect(
            ClipboardFormatText.reason(question) == String(localized: "The text can be read as more than one format."))
        let all = question.options + question.others
        #expect(all.contains { $0.evidence.contains(.conflictingSyntax) })
        let mixed = ClipboardFormatText.evidence(.conflictingSyntax, of: .markdown)
        for option in all {
            #expect(!ClipboardFormatText.evidence(of: option).contains(mixed), "\(option.kind)")
        }
        let plain = all.first { $0.kind == .plainText }
        #expect(plain.map { ClipboardFormatText.evidence(of: $0) } == String(localized: "Marks shown as they are"))
    }
}
