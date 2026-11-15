import Foundation
import Testing

@testable import SurimonoCore

struct ShortcutArchiveTests {
    private let validator = ShortcutValidator(environment: .init())
    private let x = ShortcutCombination(key: .character("x"), modifiers: [.control, .command])
    private let p = ShortcutCombination(key: .character("p"), modifiers: .command)

    private func decode(_ entries: String, version: Int = 1) throws -> ShortcutArchive {
        try ShortcutArchive.decode(
            Data(
                """
                {"format":"io.github.phyten.surimono.keyboard-shortcuts","version":\(version),"bindings":\(entries)}
                """.utf8))
    }

    @Test("書き出しは安定した文字列のキー形式と明示的な解除だけを含む")
    func format() throws {
        let configuration = ShortcutConfiguration(overrides: [
            .documentReload: [x], .styleChoose: [],
            .globalClipboardOpen: [.init(key: .macVirtualKey(38), modifiers: [.control, .option, .command])],
        ])
        let data = try ShortcutArchive(configuration: configuration).encode()
        #expect(data.last == 10)
        let actual = try JSONSerialization.jsonObject(with: data) as? NSDictionary
        let expected =
            try JSONSerialization.jsonObject(
                with: Data(
                    """
                    {"format":"io.github.phyten.surimono.keyboard-shortcuts","version":1,"bindings":[
                      {"operation":"document.reload","keys":[{"key":{"kind":"character","value":"x"},"modifiers":["control","command"]}]},
                      {"operation":"global.clipboard.open","keys":[{"key":{"kind":"macVirtualKey","code":38},"modifiers":["control","option","command"]}]},
                      {"operation":"style.choose","keys":[]}
                    ]}
                    """.utf8)) as? NSDictionary
        #expect(actual == expected)
        #expect(try ShortcutArchive.decode(data).encode() == data)
    }

    @Test("統合は省略した操作を保持し未知IDと固定IDを保存しない")
    func merge() throws {
        let original = ShortcutConfiguration(overrides: [.documentReload: [x]])
        let archive = try decode(
            """
            [{"operation":"document.print","keys":[]},{"operation":"future.action","keys":[]},
             {"operation":"fixed.cancellation","keys":[]}]
            """)
        let review = ShortcutImportReview(archive: archive, original: original)
        let plan = try review.plan(using: validator)
        #expect(plan.configuration.keys(for: .documentReload) == [x])
        #expect(plan.configuration.keys(for: .documentPrint).isEmpty)
        #expect(plan.configuration.keys(for: .documentFind) == [.init(key: .character("f"), modifiers: .command)])
        #expect(review.unknown == ["fixed.cancellation", "future.action"])
        #expect(plan.configuration.overrides.count == 2)
    }

    @Test("未変更の所有者との競合は確定を拒み選ばれたキーの別名だけを移す")
    func conflicts() throws {
        let original = ShortcutConfiguration(overrides: [.documentPrint: [p, x]])
        var review = ShortcutImportReview(
            archive: ShortcutArchive(configuration: .init(overrides: [.documentReload: [p]])), original: original)
        #expect(throws: ShortcutModelError.self) { try review.plan(using: validator) }
        review.keep(.documentReload, key: p, validator: validator)
        let plan = try review.plan(using: validator)
        #expect(plan.configuration.keys(for: .documentPrint) == [x])
        #expect(plan.configuration.keys(for: .documentReload) == [p])
        #expect(plan.requiresPrintingAcknowledgement)
    }

    @Test("現在の割当を維持すると入力された変更全体を取り消す")
    func keepCurrent() throws {
        var review = ShortcutImportReview(
            archive: ShortcutArchive(configuration: .init(overrides: [.documentReload: [p, x]])), original: .init())
        review.skip(.documentReload)
        let plan = try review.plan(using: validator)
        #expect(plan.configuration == ShortcutConfiguration())
        #expect(review.skipped == [.documentReload])
    }

    @Test("複数操作の交換は途中の競合に左右されず最終構成で判定する")
    func swap() throws {
        let archive = try decode(
            """
            [{"operation":"document.reload","keys":[{"key":{"kind":"character","value":"f"},"modifiers":["command"]}]},
             {"operation":"document.find","keys":[{"key":{"kind":"character","value":"r"},"modifiers":["command"]}]}]
            """)
        let plan = try ShortcutImportReview(archive: archive, original: .init()).plan(using: validator)
        #expect(plan.configuration.keys(for: .documentReload) == [.init(key: .character("f"), modifiers: .command)])
        #expect(plan.configuration.keys(for: .documentFind) == [.init(key: .character("r"), modifiers: .command)])
    }

    @Test("固定キーとこのMacの予約を明示的に除外するまで適用できない")
    func refusals() throws {
        let environment = ShortcutValidationContext(reservations: [.init(combination: x)])
        let validator = ShortcutValidator(environment: environment)
        var review = ShortcutImportReview(
            archive: ShortcutArchive(
                configuration: .init(overrides: [
                    .documentReload: [x], .documentPrint: [.init(key: .named(.escape), modifiers: .command)],
                ])), original: .init())
        #expect(Set(review.issues(using: validator).map(\.code)) == [.systemReserved, .cancellation])
        #expect(throws: ShortcutModelError.self) { try review.plan(using: validator) }
        review.skip(.documentReload)
        review.skip(.documentPrint)
        #expect(try review.plan(using: validator).configuration == ShortcutConfiguration())
    }

    @Test("物理グローバルキーと論理ローカルキーの重複を見つける")
    func globalConflict() throws {
        let physical = ShortcutCombination(key: .macVirtualKey(35), modifiers: .command)
        let validator = ShortcutValidator(environment: .init(projection: [.init(logical: p, physical: physical)]))
        let review = ShortcutImportReview(
            archive: ShortcutArchive(configuration: .init(overrides: [.globalClipboardOpen: [physical]])),
            original: .init())
        #expect(validator.conflicts(in: review.configuration).contains { $0.operation == .globalClipboardOpen })
        #expect(throws: ShortcutModelError.self) { try review.plan(using: validator) }
    }

    @Test("新しい版は内容が未知の形式でも版のエラーとして拒否する")
    func newerVersion() {
        #expect(throws: ShortcutModelError.unsupportedVersion(2)) {
            try decode("null", version: 2)
        }
    }

    @Test("重複操作と不正なキー・修飾・形式・上限超過を拒否する")
    func malformed() throws {
        for entries in [
            #"[{"operation":"document.reload","keys":[]},{"operation":"document.reload","keys":[]}]"#,
            #"[{"operation":"document.reload","keys":[{"key":{"kind":"character","value":"ab"},"modifiers":[]}]}]"#,
            #"[{"operation":"document.reload","keys":[{"key":{"kind":"named","value":"madeUp"},"modifiers":[]}]}]"#,
            #"[{"operation":"document.reload","keys":[{"key":{"kind":"character","value":"r"},"modifiers":["meta"]}]}]"#,
            #"[{"operation":"document.reload","keys":[{"key":{"kind":"character","value":"r","code":15},"modifiers":[]}]}]"#,
        ] {
            #expect(throws: ShortcutModelError.self) { try decode(entries) }
        }
        let key = #"{"key":{"kind":"character","value":"r"},"modifiers":["command"]}"#
        #expect(throws: ShortcutModelError.tooManyBindings) {
            try decode(
                "[{\"operation\":\"document.reload\",\"keys\":["
                    + Array(repeating: key, count: 9).joined(separator: ",") + "]}]")
        }
        #expect(throws: ShortcutModelError.tooManyEntries) {
            try decode(
                "[" + (0..<2_049).map { "{\"operation\":\"future.\($0)\",\"keys\":[]}" }.joined(separator: ",") + "]")
        }
        #expect(throws: ShortcutModelError.dataTooLarge) {
            try ShortcutArchive.decode(Data(repeating: 32, count: 1_048_577))
        }
    }
}
