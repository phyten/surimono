import Foundation
import Testing

@testable import SurimonoCore

struct ShortcutTests {
    @Test("永続操作IDと順序は翻訳やSwift名から作らない")
    func identifiers() {
        #expect(
            ShortcutOperationID.allCases.map(\.rawValue) == [
                "app.open", "clipboard.open", "app.settings", "document.print", "document.printSystem",
                "document.exportPDF", "document.find", "document.findNext", "document.findPrevious",
                "document.goToPage", "document.reload", "view.htmlPresentation", "view.spread", "view.single",
                "text.increase", "text.decrease", "text.reset", "view.zoomIn", "view.zoomOut", "view.zoomFit",
                "view.toolbarAlways", "view.toolbarToggle", "view.options", "view.selectText", "reading.left",
                "reading.right", "reading.previous", "reading.next", "print.layout.single", "print.layout.duplex",
                "print.layout.bookletLarge", "print.layout.bookletSmall", "print.layout.twoUpLarge",
                "print.layout.handout",
                "list.toggle", "list.moveUp", "list.moveDown", "list.remove", "fold.left", "fold.right",
                "global.clipboard.open", "global.clipboard.printScreen", "clipboard.openPrintScreen",
                "app.streamingPreview",
                "app.gettingStarted", "app.keyGuide", "app.checkUpdates", "document.saveAsFile", "document.add",
                "document.openBinder", "document.resetSettings", "print.settings", "style.choose",
                "print.layout.twoUpSmall",
                "print.layout.fourUp", "settingSet.save", "settingSet.manage", "view.floatOnTop", "view.outline",
                "view.documentInfo", "view.ignoreSlides", "list.sortByName", "binder.oddPageStarts", "style.compare",
                "style.favorite", "compare.shuffle", "print.foldPreview", "print.reviewIssues", "html.smartRemoval",
                "html.reviewRemoval", "print.manualDuplex", "print.duplexTest",
            ])
        #expect(ShortcutOperation.catalog.count == 72)
        #expect(Set(ShortcutOperation.catalog.map(\.id)).count == 72)
    }

    @Test("既定の印刷と別名と未割当を明示する")
    func defaults() {
        let configuration = ShortcutConfiguration()
        #expect(configuration.keys(for: .documentPrint) == [.init(key: .character("p"), modifiers: .command)])
        #expect(
            configuration.keys(for: .viewZoomIn) == [
                .init(key: .character("+"), modifiers: .command), .init(key: .character("="), modifiers: .command),
            ])
        #expect(
            configuration.keys(for: .viewToolbarToggle) == [
                .init(key: .character("m")), .init(key: .character("m"), modifiers: .shift),
            ])
        #expect(
            configuration.keys(for: .readingPrevious) == [
                .init(key: .named(.upArrow)), .init(key: .named(.space), modifiers: .shift),
            ])
        #expect(configuration.keys(for: .globalClipboardOpen) == [])
        #expect(configuration.keys(for: .clipboardOpenPrintScreen) == [])
        #expect(ShortcutValidator(environment: .init()).conflicts(in: configuration).isEmpty)
    }

    @Test("文字の大小と合成文字と句読点を配列によらず正規化する")
    func normalization() throws {
        #expect(try ShortcutCombination(key: .character("M")).normalized() == .init(key: .character("m")))
        #expect(
            try ShortcutCombination(key: .character("M"), modifiers: .shift).normalized()
                == .init(key: .character("m"), modifiers: .shift))
        #expect(
            try ShortcutCombination(key: .character("+"), modifiers: [.command, .shift]).normalized()
                == .init(key: .character("+"), modifiers: .command))
        #expect(
            try ShortcutCombination(key: .character("e\u{301}")).normalized()
                == .init(key: .character("é")))
        #expect(throws: ShortcutModelError.self) { try ShortcutCombination(key: .character("ab")).normalized() }
        #expect(throws: ShortcutModelError.self) { try ShortcutCombination(key: .character("")).normalized() }
        #expect(throws: ShortcutModelError.self) { try ShortcutCombination(key: .macVirtualKey(55)).normalized() }
        #expect(throws: ShortcutModelError.self) {
            try ShortcutCombination(key: .character("r"), modifiers: .init(rawValue: 16)).normalized()
        }
    }

    @Test("空の上書きは既定を復活させず一件復元は競合を調べる")
    func overridesAndRestore() throws {
        let validator = ShortcutValidator(environment: .init())
        let original = ShortcutConfiguration(overrides: [.documentReload: []])
        #expect(original.keys(for: .documentReload) == [])
        let plan = try validator.plan(
            replacing: .styleChoose, with: [.init(key: .character("r"), modifiers: .command)],
            in: original, resolution: .reject)
        #expect(throws: ShortcutModelError.self) {
            try validator.restore(.documentReload, in: plan.configuration, resolution: .reject)
        }
        let restored = try validator.restore(.documentReload, in: plan.configuration, resolution: .takeConflicts)
        #expect(restored.configuration.overrides[.styleChoose] == [])
        #expect(restored.configuration.overrides[.documentReload] == nil)
        #expect(try validator.restoreAll().configuration == ShortcutConfiguration())
    }

    @Test("競合解決は全所有者の一致する別名だけを原子的に外す")
    func multipleOwners() throws {
        let left = ShortcutCombination(key: .named(.leftArrow))
        let commandLeft = ShortcutCombination(key: .named(.leftArrow), modifiers: .command)
        let original = ShortcutConfiguration(overrides: [
            .readingLeft: [left, commandLeft], .foldLeft: [left, commandLeft],
        ])
        let validator = ShortcutValidator(environment: .init())
        let conflicts = validator.conflicts(for: .viewZoomIn, keys: [commandLeft], in: original)
        #expect(conflicts.first?.owners.map(\.operation) == [.readingLeft, .foldLeft])
        let plan = try validator.plan(
            replacing: .viewZoomIn, with: [commandLeft], in: original,
            resolution: .takeConflicts)
        #expect(plan.configuration.overrides[.readingLeft] == [left])
        #expect(plan.configuration.overrides[.foldLeft] == [left])
        #expect(original.keys(for: .readingLeft) == [left, commandLeft])
    }
}

struct ShortcutValidationTests {
    @Test("静的拒否理由はすべての保護規則を区別する")
    func refusalReasons() {
        let cases: [(ShortcutCombination, ShortcutValidationIssue.Code)] = [
            (.init(key: .named(.space), modifiers: .command), .spotlight),
            (.init(key: .named(.space), modifiers: [.control, .option, .shift, .command]), .spotlight),
            (.init(key: .named(.space), modifiers: .control), .inputSource),
            (.init(key: .named(.space), modifiers: [.control, .option]), .inputSource),
            (.init(key: .named(.tab), modifiers: .command), .applicationSwitching),
            (.init(key: .named(.tab), modifiers: [.shift, .command]), .applicationSwitching),
            (.init(key: .named(.escape), modifiers: [.option, .command]), .forceQuit),
            (.init(key: .named(.f1), modifiers: .control), .keyboardNavigation),
            (.init(key: .named(.f8), modifiers: .control), .keyboardNavigation),
            (.init(key: .named(.f4), modifiers: [.control, .shift]), .keyboardNavigation),
            (.init(key: .named(.f6), modifiers: [.control, .shift]), .keyboardNavigation),
            (.init(key: .named(.f5), modifiers: .command), .accessibility),
            (.init(key: .named(.f5), modifiers: [.option, .command]), .accessibility),
            (.init(key: .character("3"), modifiers: [.shift, .command]), .screenCapture),
            (.init(key: .character("6"), modifiers: [.control, .shift, .command]), .screenCapture),
            (.init(key: .character("q"), modifiers: [.control, .command]), .sessionControl),
            (.init(key: .character("q"), modifiers: [.shift, .command]), .sessionControl),
            (.init(key: .character("q"), modifiers: [.option, .shift, .command]), .sessionControl),
            (.init(key: .named(.leftArrow), modifiers: .control), .workspaceNavigation),
            (.init(key: .character("d"), modifiers: [.option, .command]), .workspaceNavigation),
            (.init(key: .named(.escape), modifiers: [.control, .command]), .cancellation),
            (.init(key: .named(.return), modifiers: [.option, .command]), .confirmation),
            (.init(key: .named(.enter)), .confirmation),
            (.init(key: .character("."), modifiers: .command), .confirmation),
            (.init(key: .named(.tab), modifiers: [.control, .command]), .focusNavigation),
            (.init(key: .character("c"), modifiers: .command), .fixedOperation),
            (.init(key: .character("s"), modifiers: [.option, .shift, .command]), .documentSaving),
            (.init(key: .character("j"), modifiers: [.control, .option]), .voiceOver),
            (.init(key: .character("j"), modifiers: [.control, .option, .shift]), .voiceOver),
        ]
        for (key, reason) in cases {
            #expect(ShortcutValidator.staticRefusal(key)?.0 == reason)
        }
        #expect(ShortcutValidator.staticRefusal(.init(key: .character("c"), modifiers: .command))?.1 == .copy)
        #expect(
            ShortcutValidator.staticRefusal(.init(key: .character("j"), modifiers: [.control, .option, .command]))
                == nil)
        #expect(ShortcutValidator.staticRefusal(.init(key: .named(.f9), modifiers: .control)) == nil)
    }

    @Test("固定編集キーと窓のキーと保存キーをすべて保護する")
    func fixedKeys() {
        let fixed: [(String, ShortcutModifiers, ShortcutFixedKey.Behavior)] = [
            ("c", .command, .copy), ("x", .command, .cut), ("v", .command, .paste), ("a", .command, .selectAll),
            ("z", .command, .undo), ("z", [.shift, .command], .redo),
            ("v", [.option, .shift, .command], .pasteMatchingStyle),
            ("w", .command, .closeWindow), ("w", [.option, .command], .closeWindow),
            ("q", .command, .quit), ("h", .command, .hide), ("h", [.option, .command], .hide),
            ("m", .command, .minimize), ("m", [.option, .command], .minimize),
            ("f", [.control, .command], .fullScreen), ("`", .command, .cycleWindows),
            ("`", [.shift, .command], .cycleWindows), ("~", .command, .cycleWindows),
            ("s", .command, .documentSaving), ("s", [.shift, .command], .documentSaving),
            ("s", [.option, .shift, .command], .documentSaving),
        ]
        for (key, flags, behavior) in fixed {
            #expect(ShortcutValidator.staticRefusal(.init(key: .character(key), modifiers: flags))?.1 == behavior)
        }
    }

    @Test("裸のキーは指定された紙面とリストと折りプレビューだけに限る")
    func bareKeys() {
        let validator = ShortcutValidator(environment: .init())
        let bare = ShortcutCombination(key: .character("j"))
        #expect(validator.issues(for: .appOpen, combination: bare).map(\.code) == [.modifierRequired])
        #expect(validator.issues(for: .documentReload, combination: bare).map(\.code) == [.modifierRequired])
        #expect(validator.issues(for: .documentPrint, combination: bare).map(\.code) == [.modifierRequired])
        #expect(validator.issues(for: .viewOptions, combination: bare) == [])
        #expect(validator.issues(for: .listRemove, combination: bare) == [])
        #expect(validator.issues(for: .foldLeft, combination: bare) == [])
        #expect(
            validator.issues(
                for: .viewOptions,
                combination: .init(key: .character("j"), modifiers: .option)
            ).map(\.code) == [.modifierRequired])
        #expect(
            validator.issues(
                for: .globalClipboardOpen,
                combination: .init(key: .macVirtualKey(38), modifiers: .shift)
            ).map(\.code) == [.globalModifierRequired])
        #expect(
            validator.issues(
                for: .documentReload,
                combination: .init(key: .macVirtualKey(38), modifiers: .command)
            ).map(\.code) == [.wrongKeyKind])
    }

    @Test("紙と折りプレビューは分離し文字選択の矢印を奪わない")
    func regions() {
        let left = ShortcutCombination(key: .named(.leftArrow))
        let paper = ShortcutOperation.operation(.readingLeft)
        #expect(paper.binding(for: left).regions == [.paperReading])
        #expect(
            paper.binding(for: .init(key: .named(.leftArrow), modifiers: .command)).regions
                == [.paperReading, .paperSelection])
        #expect(!paper.binding(for: left).overlaps(ShortcutOperation.operation(.foldLeft).binding(for: left)))
        #expect(
            ShortcutOperation.operation(.viewSelectText).binding(for: .init(key: .character("t"))).regions
                == [.paperReading, .paperSelection])
        #expect(ShortcutOperation.operation(.documentPrint).regions.contains(.foldedPreview))
        #expect(!ShortcutOperation.operation(.documentPrint).regions.contains(.modal))
        #expect(!ShortcutOperation.operation(.documentPrint).regions.contains(.recorder))
    }

    @Test("投影したグローバルとローカルの競合をすべて返す")
    func physicalProjection() throws {
        let logical = ShortcutCombination(key: .character("r"), modifiers: .command)
        let physical = ShortcutCombination(key: .macVirtualKey(15), modifiers: .command)
        let validator = ShortcutValidator(environment: .init(projection: [.init(logical: logical, physical: physical)]))
        let conflicts = validator.conflicts(for: .globalClipboardOpen, keys: [physical], in: .init())
        #expect(conflicts.first?.owners.map(\.operation) == [.documentReload])
        let plan = try validator.plan(
            replacing: .globalClipboardOpen, with: [physical], in: .init(),
            resolution: .takeConflicts)
        #expect(plan.configuration.overrides[.documentReload] == [])
        #expect(plan.requiresGlobalAcknowledgement)
        #expect(!plan.requiresPrintingAcknowledgement)
        let printing = try validator.plan(
            replacing: .documentPrint,
            with: [.init(key: .character("j"), modifiers: .command)], in: .init(), resolution: .reject)
        #expect(printing.requiresPrintingAcknowledgement)
    }

    @Test("新しい配列で別々の論理キーが同じ物理キーになれば曖昧とする")
    func layoutCollision() {
        let physical = ShortcutCombination(key: .macVirtualKey(15), modifiers: .command)
        let validator = ShortcutValidator(
            environment: .init(projection: [
                .init(logical: .init(key: .character("r"), modifiers: .command), physical: physical),
                .init(logical: .init(key: .character("o"), modifiers: .command), physical: physical),
            ]))
        #expect(
            validator.conflicts(
                for: .appOpen, keys: [.init(key: .character("o"), modifiers: .command)],
                in: .init()
            ).first?.owners.map(\.operation) == [.documentReload])
    }

    @Test("有効なシステム予約だけを拒否し取得失敗を区別する")
    func systemReservations() {
        let logical = ShortcutCombination(key: .character("="), modifiers: [.option, .command])
        let physical = ShortcutCombination(key: .macVirtualKey(24), modifiers: [.option, .command])
        for enabled in [true, false] {
            let validator = ShortcutValidator(
                environment: .init(
                    reservations: [.init(combination: physical, isEnabled: enabled)],
                    projection: [.init(logical: logical, physical: physical)]))
            #expect(
                validator.issues(for: .textIncrease, combination: logical).map(\.code)
                    == (enabled ? [.systemReserved] : []))
        }
        #expect(
            ShortcutValidator(environment: .unavailable).issues(for: .textIncrease, combination: logical)
                .map(\.code) == [.systemReservationsUnavailable])
        #expect(
            ShortcutValidator(environment: .init()).issues(for: .globalClipboardOpen, combination: physical)
                .map(\.code) == [.layoutProjectionUnavailable])
        let tab = ShortcutCombination(key: .macVirtualKey(48), modifiers: .command)
        #expect(
            ShortcutValidator(
                environment: .init(projection: [
                    .init(logical: .init(key: .named(.tab), modifiers: .command), physical: tab)
                ])
            ).issues(for: .globalClipboardOpen, combination: tab).map(\.code) == [.applicationSwitching])
    }
}

struct ShortcutStoreTests {
    @Test("保存キーとJSONの形と空の割当と修飾キー名を固定する")
    func literalFormat() throws {
        #expect(ShortcutStore.preferencesKey == "keyboardShortcuts.v1")
        let raw =
            Data(
                #"{"inactiveMigration":[],"overrides":[{"keys":[{"key":{"kind":"character","value":"r"},"modifiers":["control","option","shift","command"]}],"operation":"document.reload"},{"keys":[{"key":{"code":38,"kind":"macVirtualKey"},"modifiers":["control","option","command"]}],"operation":"global.clipboard.open"},{"keys":[],"operation":"style.choose"}],"schemaVersion":1}"#
                    .utf8) + Data([10])
        let configuration = try ShortcutStore.decode(raw)
        #expect(configuration.schemaVersion == 1)
        #expect(configuration.keys(for: .styleChoose) == [])
        #expect(
            configuration.keys(for: .documentReload) == [
                .init(key: .character("r"), modifiers: [.control, .option, .shift, .command])
            ])
        #expect(try ShortcutStore.encode(configuration) == raw)
    }

    @Test("初期化済みの空の保存も永続形式として明示する")
    func initializedDefaults() throws {
        #expect(
            try ShortcutStore.encode(.init())
                == Data(#"{"inactiveMigration":[],"overrides":[],"schemaVersion":1}"#.utf8) + Data([10]))
    }

    @Test("同じ操作の重複と未知IDと版と修飾キーとキー表現を拒否する")
    func malformed() {
        for json in [
            "not-json",
            #"{"schemaVersion":2,"overrides":[],"inactiveMigration":[]}"#,
            #"{"schemaVersion":1,"overrides":[{"operation":"future.command","keys":[]}],"inactiveMigration":[]}"#,
            #"{"schemaVersion":1,"overrides":[{"operation":"document.reload","keys":[]},{"operation":"document.reload","keys":[]}],"inactiveMigration":[]}"#,
            #"{"schemaVersion":1,"overrides":[{"operation":"document.reload","keys":[{"key":{"kind":"character","value":"r"},"modifiers":["fn"]}]}],"inactiveMigration":[]}"#,
            #"{"schemaVersion":1,"overrides":[{"operation":"document.reload","keys":[{"key":{"kind":"character","value":"r"},"modifiers":["command","command"]}]}],"inactiveMigration":[]}"#,
            #"{"schemaVersion":1,"overrides":[{"operation":"document.reload","keys":[{"key":{"kind":"character","value":"ab"},"modifiers":[]}]}],"inactiveMigration":[]}"#,
            #"{"schemaVersion":1,"overrides":[{"operation":"document.reload","keys":[{"key":{"kind":"sequence","value":"r"},"modifiers":[]}]}],"inactiveMigration":[]}"#,
        ] {
            #expect(throws: ShortcutModelError.self) { try ShortcutStore.decode(Data(json.utf8)) }
        }
    }

    @Test("保存のサイズと別名数を制限し同じ操作の別名を正規化して重複を除く")
    func limits() throws {
        #expect(throws: ShortcutModelError.dataTooLarge) {
            try ShortcutStore.decode(Data(repeating: 32, count: 1_048_577))
        }
        #expect(throws: ShortcutModelError.tooManyBindings) {
            try ShortcutConfiguration.normalizedKeys(Array(repeating: .init(key: .character("r")), count: 9))
        }
        #expect(
            try ShortcutConfiguration.normalizedKeys([
                .init(key: .character("R"), modifiers: .command), .init(key: .character("r"), modifiers: .command),
            ]) == [.init(key: .character("r"), modifiers: .command)])
    }
}

struct ShortcutInputTests {
    @Test("CapsLockとテンキーの印は捨てFnとデッドキーと連続入力を拒否する")
    func eventNormalization() throws {
        let key = ShortcutCombination(key: .character("R"), modifiers: .command)
        #expect(
            try ShortcutInput(combination: key, auxiliaryModifiers: [.capsLock, .numericPad]).normalized()
                == .init(key: .character("r"), modifiers: .command))
        #expect(throws: ShortcutModelError.invalidKey) { try ShortcutInput(combination: nil).normalized() }
        #expect(throws: ShortcutModelError.invalidKey) {
            try ShortcutInput(combination: key, auxiliaryModifiers: [.function]).normalized()
        }
        #expect(throws: ShortcutModelError.invalidKey) {
            try ShortcutInput(combination: key, isDeadKey: true).normalized()
        }
        #expect(throws: ShortcutModelError.invalidKey) {
            try ShortcutInput(combination: key, strokeCount: 2).normalized()
        }
    }
}

struct ShortcutContractTests {
    @Test("既定キーの全表と主キーの順を固定する")
    func completeDefaults() throws {
        let actual = try ShortcutOperation.catalog.filter { !$0.defaults.isEmpty }.map { operation in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return operation.id.rawValue + "="
                + (try operation.defaults.map { key in
                    let name: String
                    switch key.key {
                    case .character(let value): name = value
                    case .named(let value): name = value.rawValue
                    case .macVirtualKey(let value): name = "#\(value)"
                    }
                    return name + String(decoding: try encoder.encode(key.modifiers), as: UTF8.self)
                }).joined(separator: ";")
        }
        #expect(
            actual == [
                #"app.open=o["command"]"#, #"clipboard.open=n["command"]"#, #"app.settings=,["command"]"#,
                #"document.print=p["command"]"#, #"document.printSystem=p["option","command"]"#,
                #"document.exportPDF=e["shift","command"]"#, #"document.find=f["command"]"#,
                #"document.findNext=g["command"]"#, #"document.findPrevious=g["shift","command"]"#,
                #"document.goToPage=g["option","command"]"#, #"document.reload=r["command"]"#,
                #"view.htmlPresentation=p["control","command"]"#, #"view.spread=1["option","command"]"#,
                #"view.single=2["option","command"]"#,
                #"text.increase=+["option","command"];=["option","command"]"#,
                #"text.decrease=-["option","command"]"#, #"text.reset=0["option","command"]"#,
                #"view.zoomIn=+["command"];=["command"]"#, #"view.zoomOut=-["command"]"#,
                #"view.zoomFit=0["command"]"#, #"view.toolbarAlways=t["option","command"]"#,
                #"view.toolbarToggle=m[];m["shift"]"#, #"view.options=v[];v["shift"]"#,
                #"view.selectText=t[];t["shift"]"#, #"reading.left=leftArrow[]"#, #"reading.right=rightArrow[]"#,
                #"reading.previous=upArrow[];space["shift"]"#, #"reading.next=downArrow[];space[]"#,
                #"print.layout.single=1["command"]"#, #"print.layout.duplex=2["command"]"#,
                #"print.layout.bookletLarge=3["command"]"#, #"print.layout.bookletSmall=4["command"]"#,
                #"print.layout.twoUpLarge=5["command"]"#, #"print.layout.handout=6["command"]"#,
                #"list.toggle=s["control","command"]"#, #"list.moveUp=upArrow["option","command"]"#,
                #"list.moveDown=downArrow["option","command"]"#, #"list.remove=deleteBackward[]"#,
                #"fold.left=leftArrow[]"#, #"fold.right=rightArrow[]"#,
            ])
    }

    @Test("保護範囲の全修飾組とFキーと画面収録番号を検証する")
    func refusalFamilies() {
        for raw: UInt8 in 0..<16 {
            let flags = ShortcutModifiers(rawValue: raw)
            if flags.contains(.command) {
                #expect(ShortcutValidator.staticRefusal(.init(key: .named(.space), modifiers: flags))?.0 == .spotlight)
            }
            #expect(
                ShortcutValidator.staticRefusal(.init(key: .named(.escape), modifiers: flags))?.0
                    == (flags == [.option, .command] ? .forceQuit : .cancellation))
            for key: ShortcutNamedKey in [.return, .enter] {
                #expect(ShortcutValidator.staticRefusal(.init(key: .named(key), modifiers: flags))?.0 == .confirmation)
            }
            #expect(
                ShortcutValidator.staticRefusal(.init(key: .named(.tab), modifiers: flags))?.0
                    == (flags == .command || flags == [.shift, .command] ? .applicationSwitching : .focusNavigation))
        }
        for key: ShortcutNamedKey in [.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8] {
            #expect(
                ShortcutValidator.staticRefusal(.init(key: .named(key), modifiers: .control))?.0 == .keyboardNavigation)
        }
        for value in ["3", "4", "5", "6"] {
            for flags: ShortcutModifiers in [[.shift, .command], [.control, .shift, .command]] {
                #expect(
                    ShortcutValidator.staticRefusal(.init(key: .character(value), modifiers: flags))?.0
                        == .screenCapture)
            }
        }
        for key: ShortcutNamedKey in [.leftArrow, .rightArrow, .upArrow, .downArrow] {
            #expect(
                ShortcutValidator.staticRefusal(.init(key: .named(key), modifiers: .control))?.0 == .workspaceNavigation
            )
        }
    }

    @Test("記号になった画面収録キーも投影の基底キーから拒否する")
    func projectedRefusal() {
        let physical = ShortcutCombination(key: .macVirtualKey(20), modifiers: [.shift, .command])
        let symbol = ShortcutCombination(key: .character("#"), modifiers: .command)
        let validator = ShortcutValidator(
            environment: .init(projection: [
                .init(logical: symbol, physical: physical),
                .init(logical: .init(key: .character("3"), modifiers: [.shift, .command]), physical: physical),
            ]))
        #expect(validator.issues(for: .documentReload, combination: symbol).map(\.code) == [.screenCapture])
        #expect(validator.issues(for: .globalClipboardOpen, combination: physical).map(\.code) == [.screenCapture])
    }

    @Test("構造化した拒否理由の永続文字列を固定する")
    func reasonIdentifiers() {
        #expect(
            ShortcutValidationIssue.Code.allCases.map(\.rawValue) == [
                "invalidKey", "invalidModifiers", "wrongKeyKind", "modifierRequired", "globalModifierRequired",
                "spotlight", "inputSource", "applicationSwitching", "forceQuit", "keyboardNavigation", "accessibility",
                "screenCapture", "sessionControl", "workspaceNavigation", "cancellation", "confirmation",
                "focusNavigation",
                "fixedOperation", "documentSaving", "voiceOver", "systemReserved", "systemReservationsUnavailable",
                "layoutProjectionUnavailable", "conflict", "malformedLegacy",
            ])
        #expect(
            ShortcutNamedKey.allCases.map(\.rawValue) == [
                "leftArrow", "rightArrow", "upArrow", "downArrow", "space", "deleteBackward", "deleteForward",
                "escape", "tab", "return", "enter", "home", "end", "pageUp", "pageDown",
                "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "f13", "f14", "f15",
                "f16", "f17", "f18", "f19", "f20",
            ])
    }

    @Test("非アクティブな移行記録の形式を固定する")
    func inactiveRecord() throws {
        let configuration = ShortcutConfiguration(
            overrides: [.globalClipboardOpen: []],
            inactiveMigration: [
                .init(
                    operation: .globalClipboardOpen, legacyData: Data("bad".utf8), candidate: nil,
                    reasons: [.malformedLegacy])
            ])
        let expected =
            Data(
                #"{"inactiveMigration":[{"legacyData":"YmFk","operation":"global.clipboard.open","reasons":["malformedLegacy"]}],"overrides":[{"keys":[],"operation":"global.clipboard.open"}],"schemaVersion":1}"#
                    .utf8) + Data([10])
        #expect(try ShortcutStore.encode(configuration) == expected)
        #expect(try ShortcutStore.decode(expected) == configuration)
    }
}

struct ShortcutStoreBoundaryTests {
    @Test("未知の追加フィールドも読み捨てず保存全体を拒否する")
    func unknownFields() {
        for json in [
            #"{"schemaVersion":1,"overrides":[],"inactiveMigration":[],"future":true}"#,
            #"{"schemaVersion":1,"overrides":[{"operation":"document.reload","keys":[],"future":true}],"inactiveMigration":[]}"#,
            #"{"schemaVersion":1,"overrides":[{"operation":"document.reload","keys":[{"key":{"kind":"character","value":"r","code":15},"modifiers":["command"]}]}],"inactiveMigration":[]}"#,
        ] {
            #expect(throws: ShortcutModelError.malformedStore) { try ShortcutStore.decode(Data(json.utf8)) }
        }
    }

    @Test("エントリー数と保存中の別名数の上限を超えたデータを拒否する")
    func collectionLimits() throws {
        let entries = Array(repeating: #"{"operation":"document.reload","keys":[]}"#, count: 2_049).joined(
            separator: ",")
        #expect(throws: ShortcutModelError.tooManyEntries) {
            try ShortcutStore.decode(
                Data("{\"schemaVersion\":1,\"overrides\":[\(entries)],\"inactiveMigration\":[]}".utf8))
        }
        let keys = Array(
            repeating: #"{"key":{"kind":"character","value":"r"},"modifiers":["command"]}"#,
            count: 9
        ).joined(separator: ",")
        #expect(throws: ShortcutModelError.tooManyBindings) {
            try ShortcutStore.decode(
                Data(
                    "{\"schemaVersion\":1,\"overrides\":[{\"operation\":\"document.reload\",\"keys\":[\(keys)]}],\"inactiveMigration\":[]}"
                        .utf8))
        }
    }

    @Test("全件復元も新しい配列で生じた競合を黙って保存しない")
    func restoreValidation() {
        let physical = ShortcutCombination(key: .macVirtualKey(15), modifiers: .command)
        let validator = ShortcutValidator(
            environment: .init(projection: [
                .init(logical: .init(key: .character("r"), modifiers: .command), physical: physical),
                .init(logical: .init(key: .character("p"), modifiers: .command), physical: physical),
            ]))
        #expect(throws: ShortcutModelError.self) { try validator.restoreAll() }
        #expect(throws: ShortcutModelError.self) { try ShortcutValidator(environment: .unavailable).restoreAll() }
    }

    @Test("既存のシステム予約付き既定は保存に残し非アクティブ理由を返す")
    func suspendedDefault() throws {
        let validator = ShortcutValidator(
            environment: .init(reservations: [
                .init(combination: .init(key: .character("="), modifiers: [.option, .command]))
            ]))
        let plan = try validator.plan(replacing: .documentReload, with: [], in: .init(), resolution: .reject)
        #expect(plan.unavailableBindings.map(\.code) == [.systemReserved])
        #expect(plan.unavailableBindings.map(\.operation) == [.textIncrease])
        #expect(
            plan.configuration.keys(for: .textIncrease) == [
                .init(key: .character("+"), modifiers: [.option, .command]),
                .init(key: .character("="), modifiers: [.option, .command]),
            ])
    }
}
