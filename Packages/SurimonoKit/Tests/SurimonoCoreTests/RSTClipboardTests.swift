import Foundation
import Testing

@testable import SurimonoCore

struct RSTClipboardTests {
    @Test("貼り付けた原稿では独立した手がかりがあるときだけ RST を選ぶ")
    func detection() throws {
        let unmistakable = [
            "Mill\n====\n\n.. note:: Keep dry.",
            ".. warning::\n\n   Do not wet the desk.",
            ".. _yard: https://example.org/yard\n\nSee yard_.",
            ".. note:: Worn edge.\n\n.. tip:: Sand lightly.",
        ]
        let ambiguous = [
            "Mill\n====\n\nKeep dry.", "**Folded** paper", "New stock\n---------\n\n* One\n* Two",
            "# Examples\n\n```rst\n.. note:: Small.\n.. tip:: Thin.\n```",
            "An example\n\n    .. note:: In code\n    .. tip:: Also in code",
        ]
        let negatives =
            try ClipboardFormatCorpusTests.cases().map(\.text)
            + ClipboardFormatReviewTests.cases().map(\.text) + ambiguous
        let falsePositives = negatives.filter { ClipboardFormatDetector.detect($0).action == .open(.rst) }.count
        let missed = unmistakable.filter { ClipboardFormatDetector.detect($0).action != .open(.rst) }.count
        print(
            "RST_CLIPBOARD positive=\(unmistakable.count) negative=\(negatives.count) FP=\(falsePositives) FN=\(missed)"
        )
        #expect(falsePositives == 0)
        #expect(missed == 0)
        #expect(ClipboardTextKind.choosable.contains(.rst))
    }
}

extension RSTClipboardTests {
    @Test("実際の短い RST 原稿で自動判定率を記録する")
    func recognitionRate() throws {
        guard let folder = ProcessInfo.processInfo.environment["SURIMONO_RST_FIXTURES"] else { return }
        let root = URL(fileURLWithPath: folder)
        var total = 0
        var recognized = 0
        var otherFormats: [String] = []
        for group in ["blocks", "inline", "directives"] {
            for url in try FileManager.default.contentsOfDirectory(
                at: root.appending(path: group), includingPropertiesForKeys: nil)
            where url.pathExtension == "rst" {
                let text = TextDecoding.decode(try Data(contentsOf: url)).text
                let action = ClipboardFormatDetector.detect(text).action
                total += 1
                if action == .open(.rst) { recognized += 1 }
                if case .open(let kind) = action, kind != .rst, kind != .plainText {
                    otherFormats.append("\(group)/\(url.lastPathComponent)=\(kind.rawValue)")
                }
            }
        }
        #expect(total >= 120)
        print(
            "RST_CLIPBOARD_FIXTURES total=\(total) recognized=\(recognized) missed=\(total - recognized) others=\(otherFormats.sorted())"
        )
    }
}
