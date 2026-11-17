import AppKit
import Testing

@testable import Surimono

@MainActor
@Suite(.serialized)
struct OutlineSearchFieldTests {
    @Test("検索欄のフィールドエディタでは紙の文字キーと矢印を実行しない")
    func fieldEditorProtectsReadingKeys() throws {
        let fixture = try ShortcutSurfaceFixture()
        defer { fixture.close() }
        let field = NSSearchField()
        let editor = try #require(fixture.window.fieldEditor(true, for: field) as? NSTextView)
        fixture.responder = editor
        for key in ["m", "v", "t", " ", "\u{F700}", "\u{F701}"] {
            #expect(!fixture.dispatcher.handle(fixture.event(key)))
        }
        #expect(fixture.operations.isEmpty)
    }

    @Test("検索欄の変換中はReturnとEscと上下を入力側へ返す")
    func compositionOwnsCommands() throws {
        let fixture = try ShortcutSurfaceFixture()
        defer { fixture.close() }
        let coordinator = OutlineSearchField.Coordinator(model: fixture.model)
        let editor = NSTextView()
        editor.setMarkedText(
            "へんかん", selectedRange: NSRange(location: 0, length: 4),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        fixture.model.outlineFilter.setQuery("へんかん", entries: [])
        for command in [
            #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)),
            #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)),
        ] {
            #expect(!coordinator.control(NSSearchField(), textView: editor, doCommandBy: command))
        }
        #expect(fixture.model.outlineFilter.query == "へんかん")
    }
}
