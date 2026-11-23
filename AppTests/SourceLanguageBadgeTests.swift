import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct SourceLanguageBadgeTests {
    private func badge(_ name: String?, _ text: String = "", format: DocumentFormat = .plainText) -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = BandTestDefaultsSuite()
        defer { suite.remove() }
        let model = DocumentViewModel(
            data: Data(text.utf8), fileURL: name.map { directory.appendingPathComponent($0) }, format: format,
            preferences: AppPreferences(defaults: suite.defaults), library: UserLibrary(root: directory))
        model.isolateBandTestOutput()
        return model.shortFormatBadge
    }

    @Test("ソースコードの形式バッジは言語の名前になる")
    func sourceCode() {
        #expect(badge("main.swift") == "Swift")
        #expect(badge("main.ts") == "TypeScript")
        #expect(badge("tool.py") == "Python")
        #expect(badge("model.rb") == "Ruby")
        #expect(badge("config.yaml") == "YAML")
        #expect(badge("Makefile") == "Makefile")
    }

    @Test("拡張子のないスクリプトの形式バッジは shebang の言語になる")
    func shebang() {
        #expect(badge("tool", "#!/usr/bin/env python3\nprint(1)\n") == "Python")
    }

    @Test("文章と名前のないテキストの形式バッジは TXT のまま")
    func plainText() {
        #expect(badge("notes.txt", "#!/bin/sh\n") == "TXT")
        #expect(badge("server.log") == "TXT")
        #expect(badge(nil, "#!/bin/sh\n") == "TXT")
    }

    @Test("テキスト以外の形式のバッジは変わらない")
    func otherFormats() {
        #expect(badge("notes.md", format: .markdown) == "MD")
        #expect(badge("table.csv", format: .csv) == "CSV")
    }
}
