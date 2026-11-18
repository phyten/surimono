import Foundation
import Testing

@testable import SurimonoCore

struct NotebookConverterTests {
    func notebook(_ cells: [[String: Any]], metadata: [String: Any] = [:]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "nbformat": 4, "nbformat_minor": 5,
            "metadata": metadata, "cells": cells,
        ])
        return String(decoding: data, as: UTF8.self)
    }

    @Test("全テーマでNotebookのコード枠と非表示でない見出しを保持する")
    func themes() throws {
        let fragment = try NotebookConverter.convert(
            notebook(
                [
                    ["cell_type": "markdown", "source": "# Title\n\n## Section"],
                    ["cell_type": "code", "source": "print(1)"],
                ], metadata: ["language_info": ["name": "python"]]))
        for theme in try PrintThemeLibrary.load() {
            let html = HTMLDocumentBuilder.build(
                fragment: fragment, format: .notebook, theme: theme,
                code: CodeStyle(block: .init(lineNumbers: .all, languageLabel: .corner)))
            #expect(html.contains("surimono format-notebook"))
            #expect(html.contains("code-block"))
            #expect(html.contains("code-line"))
            #expect(!fragment.body.contains("secnum"))
        }
    }

    @Test("Notebook判定でも手動選択と毎回確認と自動判定の除外を尊重する")
    func clipboardSettings() throws {
        let source = try notebook([])
        #expect(
            ClipboardFormatDetector.detect(source, settings: .init(mode: .alwaysAsk)).action
                == .ask(preferred: .notebook))
        #expect(
            ClipboardFormatDetector.detect(source, settings: .init(mode: .fixed, fixedKind: .markdown)).action
                == .open(.markdown))
        let disabled = ClipboardFormatDetector.detect(source, settings: .init(automaticKinds: [.markdown]))
        #expect(disabled.action == .open(.plainText))
        #expect(disabled.choices.count == ClipboardTextKind.allCases.count)
        #expect(ClipboardContent.fileExtension(of: Data(source.utf8), format: .notebook) == "ipynb")
    }

    @Test("Notebookの拡張子と構造のあるクリップボードだけを判定する")
    func detection() throws {
        #expect(DocumentFormat(fileExtension: "IPYNB") == .notebook)
        #expect(DocumentFormat.notebook.usesPrintTheme)
        #expect(ClipboardFormatDetector.detect(try notebook([])).action == .open(.notebook))
        for text in [#"{"cells":[]}"#, #"{"nbformat":true,"cells":[]}"#, #"{"nbformat":4,"cells":"x"}"#] {
            #expect(ClipboardFormatDetector.detect(text).action != .open(.notebook))
        }
    }
}
