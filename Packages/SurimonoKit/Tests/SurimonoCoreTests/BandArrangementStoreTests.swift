import Foundation
import SurimonoCore
import Testing

struct BandArrangementStoreTests {
    private let id = UUID(uuidString: "82A9DE17-83DC-4E32-9756-26CB8D832F19")!

    @Test("手書き配置の省略部品は保存と上書きで未使用へ補い領域と順序を保つ")
    func completesOmittedParts() throws {
        let split = BandArrangement(
            entries: [
                .topLeft: [.part(.style), .separator, .part(.outline)], .bottomRight: [.part(.print)],
            ], unused: [.zoom])
        let top = BandArrangement(topRight: [.print, .readingDirection])
        let layouts = BandArrangementVariants(split: split, top: top)
        var store = BandArrangementStore()
        let set = BandArrangementSet(name: "Sparse", layouts: layouts)
        try store.insert(set)
        #expect(store.activeLayouts.split.topLeft == split.topLeft)
        #expect(store.activeLayouts.split.bottomRight == [.part(.print)])
        #expect(
            store.activeLayouts.split.unused == [.zoom]
                + BandLayout.Item.allCases.filter {
                    ![.zoom, .style, .outline, .print].contains($0)
                })
        #expect(store.activeLayouts.top.topRight == top.topRight)
        #expect(BandArrangementValidation.issues(in: store.activeLayouts.top, for: .top).isEmpty)
        let completed = store.activeLayouts
        try store.overwrite(.user(set.id), layouts: layouts)
        #expect(store.activeLayouts == completed)
        let loaded = BandArrangementStore.load(try JSONEncoder().encode(store))
        #expect(loaded.store == store)
        #expect(loaded.notices.isEmpty)
    }

    @Test("省略を補っても印刷の欠落と除外と重複と不正な領域は保存せずストアを保つ")
    func completionDoesNotHideInvalidDrafts() throws {
        var store = BandArrangementStore()
        let set = BandArrangementSet(name: "Valid")
        try store.insert(set)
        let before = store
        let invalid: [(BandArrangement, BandArrangementIssue)] = [
            (BandArrangement(topLeft: [.style]), .missing(.print)),
            (BandArrangement(unused: [.print]), .printIsUnused),
            (BandArrangement(topRight: [.print, .style, .style]), .duplicate(.style)),
            (BandArrangement(bottomRight: [.print]), .bottomZoneInTopOnly(.bottomRight)),
        ]
        for (top, issue) in invalid {
            let layouts = BandArrangementVariants(top: top)
            #expect(throws: BandArrangementStoreError.invalidLayout(.top, [issue])) {
                try store.insert(BandArrangementSet(name: "Invalid", layouts: layouts))
            }
            #expect(throws: BandArrangementStoreError.invalidLayout(.top, [issue])) {
                try store.overwrite(.user(set.id), layouts: layouts)
            }
            #expect(store == before)
        }
    }

    @Test("配置セットと選択中の識別子を一つの値として往復できる")
    func roundTrip() throws {
        var store = BandArrangementStore()
        try store.insert(BandArrangementSet(id: id, name: " Reading "))
        let restored = try JSONDecoder().decode(BandArrangementStore.self, from: JSONEncoder().encode(store))
        #expect(restored == store)
        #expect(restored.active == .user(id))
        #expect(restored.sets.first?.name == "Reading")
        #expect(restored.schemaVersion == 1)
    }

    @Test("名前変更と上書きは識別子を保ち名前では別のセットを置き換えない")
    func identity() throws {
        var store = BandArrangementStore()
        try store.insert(BandArrangementSet(id: id, name: "Reading"))
        try store.rename(.user(id), to: "Book")
        var layouts = BandArrangementVariants()
        layouts.split = try layouts.split.moving(.print, to: .zone(.bottomRight), for: .split)
        try store.overwrite(.user(id), layouts: layouts)
        #expect(store.active == .user(id))
        #expect(store.sets.first?.id == id && store.sets.first?.name == "Book")
        #expect(
            store.activeLayouts.split.bottomRight.compactMap(\.item) == [
                .chapter, .pageIndicator, .pageTurn, .readingSettings, .print,
            ])
        #expect(throws: BandArrangementStoreError.duplicateIdentity) {
            try store.insert(BandArrangementSet(id: id, name: "Other"))
        }
        #expect(throws: BandArrangementStoreError.duplicateName) {
            try store.insert(BandArrangementSet(name: " ＢＯＯＫ "))
        }
        #expect(throws: BandArrangementStoreError.emptyName) { try store.rename(.user(id), to: " \n ") }
    }

    @Test("標準は上書きも名前変更も削除もできない")
    func standardIsImmutable() {
        var store = BandArrangementStore()
        #expect(throws: BandArrangementStoreError.standardIsReadOnly) { try store.rename(.standard, to: "Other") }
        #expect(throws: BandArrangementStoreError.standardIsReadOnly) {
            try store.overwrite(.standard, layouts: .init())
        }
        #expect(throws: BandArrangementStoreError.standardIsReadOnly) { try store.delete(.standard) }
        #expect(store.active == .standard && store.sets == [])
    }

    @Test("使用中の配置の削除は代わりの選択を同時に行い失敗時はどちらも変えない")
    func atomicDeletion() throws {
        var store = BandArrangementStore()
        try store.insert(BandArrangementSet(id: id, name: "Reading"))
        let before = store
        #expect(throws: BandArrangementStoreError.replacementRequired) { try store.delete(.user(id)) }
        #expect(store == before)
        #expect(throws: BandArrangementStoreError.invalidReplacement) {
            try store.delete(.user(id), replacement: .user(id))
        }
        #expect(store == before)
        #expect(throws: BandArrangementStoreError.missingSet) { try store.select(.user(UUID())) }
        #expect(store == before)
        try store.delete(.user(id), replacement: .standard)
        #expect(store.active == .standard && store.sets == [])
    }

    @Test("壊れたレコードの前後と片方だけの配置を復旧して残す")
    func recordIsolation() throws {
        let data = Data(
            """
            {"schemaVersion":1,"active":{"kind":"user","id":"82A9DE17-83DC-4E32-9756-26CB8D832F19"},"sets":[
              {"id":"82A9DE17-83DC-4E32-9756-26CB8D832F19","name":"Reading",
               "layouts":{"split":{"topLeft":["style","future"],"topRight":["print"]},"top":23}},
              false, {"id":"bad","name":"Bad"},
              {"id":"00000000-0000-0000-0000-000000000002","name":"Second","layouts":{}}
            ]}
            """.utf8)
        let loaded = BandArrangementStore.load(data)
        #expect(loaded.store.sets.map(\.name) == ["Reading", "Second"])
        #expect(loaded.store.active == .user(id))
        #expect(loaded.store.sets[0].layouts.split.topLeft.compactMap(\.item) == [.style])
        #expect(
            loaded.store.sets[0].layouts.top.topLeft.compactMap(\.item) == [.formatBadge, .pageIndicator, .chapter])
        #expect(loaded.notices.contains(.invalidRecord(1)) && loaded.notices.contains(.invalidRecord(2)))
        #expect(loaded.notices.contains(.recoveredVariant(.top)))
        let roundTrip = BandArrangementStore.load(try JSONEncoder().encode(loaded.store))
        #expect(roundTrip.store == loaded.store)
        #expect(StoredBandArrangement(roundTrip.store.sets[0].layouts.split).topLeft == ["style", "future"])
    }

    @Test("存在しない選択は標準に戻り重複した識別子と正規化名は最初だけを残す")
    func duplicateRecords() {
        let data = Data(
            """
            {"schemaVersion":1,"active":{"kind":"user","id":"00000000-0000-0000-0000-000000000099"},"sets":[
              {"id":"00000000-0000-0000-0000-000000000001","name":"Book","layouts":{}},
              {"id":"00000000-0000-0000-0000-000000000001","name":"Other","layouts":{}},
              {"id":"00000000-0000-0000-0000-000000000002","name":"ＢＯＯＫ","layouts":{}}
            ]}
            """.utf8)
        let loaded = BandArrangementStore.load(data)
        #expect(loaded.store.sets.map(\.name) == ["Book"])
        #expect(loaded.store.active == .standard)
        #expect(loaded.notices.contains(.missingActiveSet))
    }

    @Test("将来の保存形式と壊れた全体は生のデータを保持して標準で開く")
    func futureSchema() {
        let data = Data(#"{"schemaVersion":99,"sets":"future"}"#.utf8)
        let loaded = BandArrangementStore.load(data)
        #expect(loaded.retainedData == data)
        #expect(loaded.store.active == .standard && loaded.store.sets == [])
        #expect(loaded.notices == [.unsupportedSchema(99)])
        let broken = BandArrangementStore.load(Data("broken".utf8))
        #expect(broken.retainedData == Data("broken".utf8) && broken.notices == [.malformedStore])
        #expect(BandArrangementStore.load(nil).notices == [])
    }
}

extension BandArrangementStoreTests {
    @Test("以前に標準を選んで保存した人は標準を選び直すまで元の帯を使う")
    func savedStandard() throws {
        let old = Data(#"{"schemaVersion":1,"active":{"kind":"standard"},"sets":[]}"#.utf8)
        var store = try JSONDecoder().decode(BandArrangementStore.self, from: old)
        let original = store.activeLayouts
        #expect(original.split.topRight == [.part(.floatOnTop), .part(.print)])
        #expect(original.split.bottomLeft.contains(.transition))
        #expect(original.top.topRight.contains(.floatOnTop) && original.top.topRight.contains(.transition))
        try store.insert(.init(name: "Copy"), activate: false)
        store = try JSONDecoder().decode(BandArrangementStore.self, from: JSONEncoder().encode(store))
        #expect(store.activeLayouts == original)
        try store.select(.standard)
        let reloaded = try JSONDecoder().decode(BandArrangementStore.self, from: JSONEncoder().encode(store))
        #expect(reloaded.activeLayouts.split.topRight == [.part(.print)])
        #expect(reloaded.activeLayouts.top.unused.contains(.floatOnTop))
        #expect(reloaded.activeLayouts.split.unused.contains(.transition))
    }
}
