import Foundation
import Testing

@testable import SurimonoCore

/// v0.30.0 uses this same reader/writer with exactly these twelve known parts.
/// Keep the JSON literal: encoding a runtime standard would silently change the compatibility fixture.
struct BandCompatibilityTests {
    private let oldItems: [BandLayout.Item] = [
        .formatBadge, .pageIndicator, .presentation, .style, .outline, .layout,
        .transition, .zoom, .thumbnails, .floatOnTop, .pageTurn, .print,
    ]
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private let oldJSON = #"""
        {"schemaVersion":1,"active":{"kind":"user","id":"00000000-0000-0000-0000-000000000001"},"sets":[
          {"id":"00000000-0000-0000-0000-000000000001","name":"Reading","layouts":{
            "split":{"topLeft":["formatBadge","@separator","style"],"topRight":["print","floatOnTop"],
              "bottomLeft":["outline","@separator","presentation"],"bottomRight":["pageIndicator","pageTurn"],
              "unused":["zoom","transition","thumbnails","layout"]},
            "top":{"topLeft":["pageIndicator","@separator","formatBadge"],"topRight":["style","print"],
              "bottomLeft":[],"bottomRight":[],
              "unused":["pageTurn","floatOnTop","thumbnails","zoom","transition","layout","outline","presentation"]}}},
          {"id":"00000000-0000-0000-0000-000000000002","name":"Second","layouts":{
            "split":{"topLeft":["formatBadge","pageIndicator","presentation","style","outline","layout"],
              "topRight":["transition","zoom","thumbnails","floatOnTop","pageTurn","print"],
              "bottomLeft":[],"bottomRight":[],"unused":[]},
            "top":{"topLeft":["formatBadge","pageIndicator","presentation","style","outline","layout"],
              "topRight":["transition","zoom","thumbnails","floatOnTop","pageTurn","print"],
              "bottomLeft":[],"bottomRight":[],"unused":[]}}}
        ]}
        """#

    private let futureJSON = #"""
        {"schemaVersion":1,"active":{"kind":"user","id":"00000000-0000-0000-0000-000000000001"},"sets":[
          {"id":"00000000-0000-0000-0000-000000000001","name":"Reading","layouts":{
            "split":{"topLeft":["readingDirection","formatBadge","@separator","scrollDirection","paperOrientation","style","paperSeries"],
              "topRight":["cover","print","selectText","@separator","floatOnTop","alwaysShowToolbar"],
              "bottomLeft":["margins","outline","@separator","printSettings","presentation","ignoreSlides"],
              "bottomRight":["beforePrinting","pageIndicator","viewOptions","pageTurn","saveAsFile"],
              "unused":["keysAndGestures","zoom","transition","thumbnails","layout"]},
            "top":{"topLeft":["readingDirection","pageIndicator","@separator","scrollDirection","formatBadge","paperOrientation"],
              "topRight":["paperSeries","style","cover","selectText","@separator","print","alwaysShowToolbar"],
              "bottomLeft":[],"bottomRight":[],
              "unused":["margins","pageTurn","printSettings","ignoreSlides","floatOnTop","thumbnails","zoom",
                "transition","layout","outline","presentation","beforePrinting","viewOptions","saveAsFile","keysAndGestures"]}}},
          {"id":"00000000-0000-0000-0000-000000000002","name":"Second","layouts":{
            "split":{"topLeft":["formatBadge","pageIndicator","presentation","style","outline","layout"],
              "topRight":["transition","zoom","thumbnails","floatOnTop","pageTurn","print"],
              "bottomLeft":[],"bottomRight":[],"unused":[]},
            "top":{"topLeft":["formatBadge","pageIndicator","presentation","style","outline","layout"],
              "topRight":["transition","zoom","thumbnails","floatOnTop","pageTurn","print"],
              "bottomLeft":[],"bottomRight":[],"unused":[]}}}
        ]}
        """#

    // Raw arrays freeze every position independently of the typed catalog and its repair implementation.
    private struct RawStore: Decodable, Equatable {
        struct Record: Decodable, Equatable {
            struct Layouts: Decodable, Equatable {
                let split: StoredBandArrangement
                let top: StoredBandArrangement
            }
            let id: UUID
            let name: String
            let layouts: Layouts
        }
        let schemaVersion: Int
        let active: BandArrangementSelection
        let sets: [Record]
    }

    private func raw(_ data: Data) throws -> RawStore { try JSONDecoder().decode(RawStore.self, from: data) }
    private func saved(_ store: BandArrangementStore) throws -> RawStore { try raw(JSONEncoder().encode(store)) }

    @Test("v0.30.0の領域と区切りと未使用順と全セットの識別子と名前と選択を変えずに読む")
    func oldStore() throws {
        let data = Data(oldJSON.utf8)
        let loaded = BandArrangementStore.load(data)
        #expect(loaded.retainedData == nil)
        #expect(
            loaded.notices
                == Array(repeating: BandLayoutTests.addedItems.map(BandRepairNotice.addedToUnused), count: 4).flatMap {
                    $0
                })
        #expect(loaded.store.schemaVersion == 1)
        #expect(loaded.store.sets.map(\.id) == [id, secondID])
        #expect(loaded.store.sets.map(\.name) == ["Reading", "Second"])
        #expect(loaded.store.active == .user(id))
        #expect(
            loaded.store.activeLayouts.split.unused == [.zoom, .transition, .thumbnails, .layout]
                + BandLayoutTests.addedItems)
        let before = try raw(data)
        let after = try saved(loaded.store)
        for (old, new) in zip(before.sets, after.sets) {
            for (oldLayout, newLayout) in [(old.layouts.split, new.layouts.split), (old.layouts.top, new.layouts.top)] {
                #expect(newLayout.topLeft == oldLayout.topLeft)
                #expect(newLayout.topRight == oldLayout.topRight)
                #expect(newLayout.bottomLeft == oldLayout.bottomLeft)
                #expect(newLayout.bottomRight == oldLayout.bottomRight)
                #expect(newLayout.unused == oldLayout.unused + BandLayoutTests.addedItems.map(\.rawValue))
            }
        }
        let again = BandArrangementStore.load(try JSONEncoder().encode(loaded.store))
        #expect(again.store == loaded.store)
        #expect(again.notices == [])
    }

    @Test("十四の新識別子は旧十二部品の配置を壊さず非破壊の未知配置として残る")
    func futureStore() throws {
        let loaded = BandArrangementStore.load(Data(futureJSON.utf8), knownItems: oldItems)
        #expect(loaded.retainedData == nil)
        #expect(loaded.store.sets.map(\.id) == [id, secondID])
        #expect(loaded.store.sets.map(\.name) == ["Reading", "Second"])
        #expect(loaded.store.active == .user(id))
        let split = loaded.store.activeLayouts.split
        #expect(split.topLeft == [.part(.formatBadge), .separator, .part(.style)])
        #expect(split.topRight == [.part(.print), .separator, .part(.floatOnTop)])
        #expect(split.bottomLeft == [.part(.outline), .separator, .part(.presentation)])
        #expect(split.bottomRight == [.part(.pageIndicator), .part(.pageTurn)])
        #expect(split.unused == [.zoom, .transition, .thumbnails, .layout])
        #expect(
            split.unknownPlacements == [
                .init(id: "readingDirection", destination: .zone(.topLeft), index: 0),
                .init(id: "scrollDirection", destination: .zone(.topLeft), index: 3),
                .init(id: "paperOrientation", destination: .zone(.topLeft), index: 4),
                .init(id: "paperSeries", destination: .zone(.topLeft), index: 6),
                .init(id: "cover", destination: .zone(.topRight), index: 0),
                .init(id: "selectText", destination: .zone(.topRight), index: 2),
                .init(id: "alwaysShowToolbar", destination: .zone(.topRight), index: 5),
                .init(id: "margins", destination: .zone(.bottomLeft), index: 0),
                .init(id: "printSettings", destination: .zone(.bottomLeft), index: 3),
                .init(id: "ignoreSlides", destination: .zone(.bottomLeft), index: 5),
                .init(id: "beforePrinting", destination: .zone(.bottomRight), index: 0),
                .init(id: "viewOptions", destination: .zone(.bottomRight), index: 2),
                .init(id: "saveAsFile", destination: .zone(.bottomRight), index: 4),
                .init(id: "keysAndGestures", destination: .unused, index: 0),
            ])
        #expect(
            loaded.notices == [
                .unknownID("readingDirection"), .unknownID("scrollDirection"), .unknownID("paperOrientation"),
                .unknownID("paperSeries"), .unknownID("cover"), .unknownID("selectText"),
                .unknownID("alwaysShowToolbar"),
                .unknownID("margins"), .unknownID("printSettings"), .unknownID("ignoreSlides"),
                .unknownID("beforePrinting"), .unknownID("viewOptions"), .unknownID("saveAsFile"),
                .unknownID("keysAndGestures"),
                .unknownID("readingDirection"), .unknownID("scrollDirection"), .unknownID("paperOrientation"),
                .unknownID("paperSeries"), .unknownID("cover"), .unknownID("selectText"),
                .unknownID("alwaysShowToolbar"),
                .unknownID("margins"), .unknownID("printSettings"), .unknownID("ignoreSlides"),
                .unknownID("beforePrinting"), .unknownID("viewOptions"), .unknownID("saveAsFile"),
                .unknownID("keysAndGestures"),
            ])
    }

    @Test("旧十二部品で再保存しても十四識別子が元の領域と相対位置へ戻る")
    func futureRoundTrip() throws {
        let data = Data(futureJSON.utf8)
        let old = BandArrangementStore.load(data, knownItems: oldItems)
        let encoded = try JSONEncoder().encode(old.store)
        #expect(try raw(encoded) == raw(data))
        let current = BandArrangementStore.load(encoded)
        #expect(try saved(current.store).sets[0] == raw(data).sets[0])
        #expect(current.store.sets[1].layouts.split.unused == BandLayoutTests.addedItems)
        #expect(current.store.sets[1].layouts.top.unused == BandLayoutTests.addedItems)
        let split = current.store.activeLayouts.split
        #expect(split.unknownPlacements == [])
        #expect(
            split.topLeft == [
                .part(.readingDirection), .part(.formatBadge), .separator, .part(.scrollDirection),
                .part(.paperOrientation), .part(.style), .part(.paperSeries),
            ])
        #expect(
            split.topRight == [
                .part(.cover), .part(.print), .part(.selectText), .separator, .part(.floatOnTop),
                .part(.alwaysShowToolbar),
            ])
        #expect(
            split.bottomLeft == [
                .part(.margins), .part(.outline), .separator, .part(.printSettings), .part(.presentation),
                .part(.ignoreSlides),
            ])
        #expect(
            split.bottomRight == [
                .part(.beforePrinting), .part(.pageIndicator), .part(.viewOptions), .part(.pageTurn),
                .part(.saveAsFile),
            ])
        #expect(split.unused == [.keysAndGestures, .zoom, .transition, .thumbnails, .layout])
        let top = current.store.activeLayouts.top
        #expect(top.unknownPlacements == [])
        #expect(
            top.topLeft == [
                .part(.readingDirection), .part(.pageIndicator), .separator, .part(.scrollDirection),
                .part(.formatBadge), .part(.paperOrientation),
            ])
        #expect(
            top.topRight == [
                .part(.paperSeries), .part(.style), .part(.cover), .part(.selectText), .separator, .part(.print),
                .part(.alwaysShowToolbar),
            ])
        #expect(
            top.unused == [
                .margins, .pageTurn, .printSettings, .ignoreSlides, .floatOnTop, .thumbnails, .zoom, .transition,
                .layout, .outline, .presentation, .beforePrinting, .viewOptions, .saveAsFile, .keysAndGestures,
            ])
    }

    @Test("旧版の名前変更と複製と上書きは未知配置を両方の表示方式で保持する")
    func setEdits() throws {
        var store = BandArrangementStore.load(Data(futureJSON.utf8), knownItems: oldItems).store
        let original = store.activeLayouts
        try store.rename(.user(id), to: "Renamed")
        #expect(store.activeLayouts == original)
        let copyID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        try store.insert(.init(id: copyID, name: "Copy", layouts: original), knownItems: oldItems)
        try store.overwrite(.user(secondID), layouts: original, knownItems: oldItems)
        let restored = BandArrangementStore.load(try JSONEncoder().encode(store))
        #expect(restored.store.sets.map(\.id) == [id, secondID, copyID])
        #expect(restored.store.sets.map(\.name) == ["Renamed", "Second", "Copy"])
        #expect(restored.store.active == .user(copyID))
        let expected = try raw(Data(futureJSON.utf8)).sets[0].layouts
        #expect(try saved(restored.store).sets.map(\.layouts) == [expected, expected, expected])
    }

    @Test("旧版で既知部品を領域内と領域間と未使用へ動かしても未知識別子を失わない")
    func partEdits() throws {
        var store = BandArrangementStore.load(Data(futureJSON.utf8), knownItems: oldItems).store
        var layouts = store.activeLayouts
        var split = layouts.split
        split = try split.moving(.style, to: .zone(.topLeft), before: .formatBadge, for: .split, knownItems: oldItems)
        #expect(
            StoredBandArrangement(split).topLeft == [
                "readingDirection", "style", "formatBadge", "@separator", "scrollDirection", "paperOrientation",
                "paperSeries",
            ])
        split = try split.moving(
            .style, to: .zone(.bottomLeft), before: .presentation, for: .split, knownItems: oldItems)
        #expect(
            StoredBandArrangement(split).topLeft == [
                "readingDirection", "formatBadge", "@separator", "scrollDirection", "paperOrientation", "paperSeries",
            ])
        #expect(
            StoredBandArrangement(split).bottomLeft == [
                "margins", "outline", "@separator", "printSettings", "style", "presentation", "ignoreSlides",
            ])
        split = try split.moving(.style, to: .unused, before: .transition, for: .split, knownItems: oldItems)
        #expect(
            StoredBandArrangement(split).unused == [
                "keysAndGestures", "zoom", "style", "transition", "thumbnails", "layout",
            ])
        split = try split.moving(.style, to: .zone(.topLeft), for: .split, knownItems: oldItems)
        #expect(
            StoredBandArrangement(split).topLeft == [
                "readingDirection", "formatBadge", "@separator", "scrollDirection", "paperOrientation", "paperSeries",
                "style",
            ])
        layouts.split = split
        try store.overwrite(.user(id), layouts: layouts, knownItems: oldItems)
        let restored = BandArrangementStore.load(try JSONEncoder().encode(store))
        let actual = try saved(restored.store)
        var expected = try raw(Data(futureJSON.utf8)).sets[0].layouts.split
        expected.topLeft = [
            "readingDirection", "formatBadge", "@separator", "scrollDirection", "paperOrientation", "paperSeries",
            "style",
        ]
        #expect(actual.sets[0].layouts.split == expected)
        #expect(actual.sets[0].layouts.top == (try raw(Data(futureJSON.utf8))).sets[0].layouts.top)
    }

    @Test("旧版で未知識別子の隣へ区切りを挿入して削除すると元の全配置へ戻る")
    func separatorEdits() throws {
        let store = BandArrangementStore.load(Data(futureJSON.utf8), knownItems: oldItems).store
        var layouts = store.activeLayouts
        for mode in [MenuArrangement.split, .top] {
            let original = layouts.arrangement(for: mode)
            let inserted = try original.insertingSeparator(at: 2, in: .topLeft, for: mode, knownItems: oldItems)
            if mode == .split {
                #expect(
                    StoredBandArrangement(inserted).topLeft == [
                        "readingDirection", "formatBadge", "@separator", "scrollDirection", "paperOrientation",
                        "@separator", "style", "paperSeries",
                    ])
            } else {
                #expect(
                    StoredBandArrangement(inserted).topLeft == [
                        "readingDirection", "pageIndicator", "@separator", "scrollDirection", "@separator",
                        "formatBadge", "paperOrientation",
                    ])
            }
            let removed = try inserted.removingSeparator(at: 2, in: .topLeft, for: mode, knownItems: oldItems)
            #expect(removed == original)
            if mode == .split { layouts.split = removed } else { layouts.top = removed }
        }
        var edited = store
        try edited.overwrite(.user(id), layouts: layouts, knownItems: oldItems)
        #expect(try saved(edited) == raw(Data(futureJSON.utf8)))
    }

    @Test("既知集合から外した実在部品も編集中は未知として保持し再び既知になると部品へ戻す")
    func typedPromotion() throws {
        let narrow = oldItems.filter { $0 != .formatBadge && $0 != .style }
        var store = BandArrangementStore.load(Data(oldJSON.utf8), knownItems: narrow).store
        var layouts = store.activeLayouts
        #expect(layouts.split.topLeft == [.separator])
        layouts.split = try layouts.split.removingSeparator(at: 0, in: .topLeft, for: .split, knownItems: narrow)
        #expect(StoredBandArrangement(layouts.split).topLeft == ["formatBadge", "style"])
        layouts.split = try layouts.split.moving(.outline, to: .zone(.topLeft), for: .split, knownItems: narrow)
        #expect(StoredBandArrangement(layouts.split).topLeft == ["formatBadge", "style", "outline"])
        try store.overwrite(.user(id), layouts: layouts, knownItems: narrow)
        let copyID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        try store.insert(.init(id: copyID, name: "Copy", layouts: layouts), knownItems: narrow)
        let promoted = BandArrangementStore.load(try JSONEncoder().encode(store), knownItems: oldItems)
        #expect(promoted.notices == [])
        #expect(promoted.store.activeLayouts.split.unknownPlacements == [])
        #expect(promoted.store.activeLayouts.split.topLeft == [.part(.formatBadge), .part(.style), .part(.outline)])
        #expect(promoted.store.activeLayouts.split.bottomLeft == [.separator, .part(.presentation)])
        #expect(promoted.store.activeLayouts.top.topLeft == [.part(.pageIndicator), .separator, .part(.formatBadge)])
        #expect(promoted.store.activeLayouts.top.topRight == [.part(.style), .part(.print)])
    }

    @Test("壊れた表示方式を標準へ戻す経路も指定された既知集合だけを使う")
    func recoveryCatalog() {
        let data = Data(
            #"""
            {"schemaVersion":1,"active":{"kind":"user","id":"00000000-0000-0000-0000-000000000001"},"sets":[
              {"id":"00000000-0000-0000-0000-000000000001","name":"Variant","layouts":{"split":false,"top":false}},
              {"id":"00000000-0000-0000-0000-000000000002","name":"Layouts","layouts":false}
            ]}
            """#.utf8)
        let loaded = BandArrangementStore.load(data, knownItems: [.print, .formatBadge])
        #expect(loaded.store.sets.map(\.name) == ["Variant", "Layouts"])
        for set in loaded.store.sets {
            for mode in [MenuArrangement.split, .top] {
                let arrangement = set.layouts.arrangement(for: mode)
                #expect(arrangement.topLeft == [.part(.formatBadge)])
                #expect(arrangement.topRight.compactMap(\.item) == [.print])
                #expect(arrangement.unused == [])
                #expect(arrangement.unknownPlacements == [])
                #expect(
                    BandArrangementValidation.issues(in: arrangement, for: mode, knownItems: [.print, .formatBadge])
                        == [])
            }
        }
        #expect(
            loaded.notices == [
                .recoveredVariant(.split), .recoveredVariant(.top), .recoveredVariant(.split), .recoveredVariant(.top),
            ])
    }

    @Test("全ビルドが知らない未来の識別子も現在の読み書きと編集で残る")
    func unknownForever() throws {
        let json = futureJSON.replacingOccurrences(of: "readingDirection", with: "futurePart2040")
        var store = BandArrangementStore.load(Data(json.utf8)).store
        try store.rename(.user(id), to: "Future")
        let expected = store.activeLayouts
        let loaded = BandArrangementStore.load(try JSONEncoder().encode(store))
        #expect(loaded.store.activeLayouts == expected)
        #expect(loaded.notices.contains(.unknownID("futurePart2040")))
        #expect(
            StoredBandArrangement(loaded.store.activeLayouts.split).topLeft == [
                "futurePart2040", "formatBadge", "@separator", "scrollDirection", "paperOrientation", "style",
                "paperSeries",
            ])
    }

    @Test("未対応版と壊れたJSONは復旧前の原データをバイト単位で返す")
    func unreadable() {
        let unsupported = Data(#" { "schemaVersion": 99, "future": ["do not overwrite"] } "#.utf8)
        let broken = Data(#"{"schemaVersion":1,"sets":["#.utf8)
        let version = BandArrangementStore.load(unsupported, knownItems: oldItems)
        let malformed = BandArrangementStore.load(broken, knownItems: oldItems)
        #expect(version.retainedData == unsupported)
        #expect(version.notices == [.unsupportedSchema(99)])
        #expect(malformed.retainedData == broken)
        #expect(malformed.notices == [.malformedStore])
        #expect(version.store.sets == [] && malformed.store.sets == [])
        #expect(version.store.active == .standard && malformed.store.active == .standard)
    }

    @Test("不足部品の追加通知と未知識別子の通知だけなら既存の配置を修復で動かさない")
    func missingParts() throws {
        let stored = try JSONDecoder().decode(
            StoredBandArrangement.self,
            from: Data(
                #"""
                {"topLeft":["readingDirection","style","@separator"],"topRight":["print"],
                 "bottomLeft":[],"bottomRight":[],"unused":["zoom","keysAndGestures","layout"]}
                """#.utf8))
        let result = BandArrangementRepair.repair(stored, for: .split, knownItems: oldItems)
        #expect(result.stored.topLeft == ["readingDirection", "style", "@separator"])
        #expect(result.stored.topRight == ["print"])
        #expect(result.stored.bottomLeft == [] && result.stored.bottomRight == [])
        #expect(
            result.stored.unused == [
                "zoom", "keysAndGestures", "layout", "formatBadge", "pageIndicator", "presentation", "outline",
                "transition", "thumbnails", "floatOnTop", "pageTurn",
            ])
        #expect(
            result.notices == [
                .unknownID("readingDirection"), .unknownID("keysAndGestures"), .addedToUnused(.formatBadge),
                .addedToUnused(.pageIndicator), .addedToUnused(.presentation), .addedToUnused(.outline),
                .addedToUnused(.transition), .addedToUnused(.thumbnails), .addedToUnused(.floatOnTop),
                .addedToUnused(.pageTurn),
            ])
    }

    @Test("区切りの予約語は部品と衝突せず既知部品の重複だけを従来どおり修復する")
    func duplicates() throws {
        #expect(BandEntry.separatorToken == "@separator")
        #expect(BandLayout.Item(rawValue: "@separator") == nil)
        #expect(!BandLayout.Item.allCases.contains { $0.rawValue.hasPrefix("@") })
        let stored = try JSONDecoder().decode(
            StoredBandArrangement.self,
            from: Data(
                #"""
                {"topLeft":["style","readingDirection","style","@separator","@separator","readingDirection"],
                 "topRight":["print","print"],"bottomLeft":[],"bottomRight":[],
                 "unused":["style","@separator","formatBadge","pageIndicator","presentation","outline","layout",
                   "transition","zoom","thumbnails","floatOnTop","pageTurn"]}
                """#.utf8))
        let result = BandArrangementRepair.repair(stored, for: .split, knownItems: oldItems)
        #expect(result.stored.topLeft == ["style", "readingDirection", "@separator", "@separator", "readingDirection"])
        #expect(result.stored.topRight == ["print"])
        #expect(
            result.stored.unused == [
                "formatBadge", "pageIndicator", "presentation", "outline", "layout", "transition", "zoom", "thumbnails",
                "floatOnTop", "pageTurn",
            ])
        #expect(
            result.notices == [
                .unknownID("readingDirection"), .duplicate(.style), .unknownID("readingDirection"),
                .duplicate(.print), .duplicate(.style), .removedUnusedSeparator,
            ])
        #expect(BandArrangementRepair.repair(result.stored, for: .split, knownItems: oldItems).stored == result.stored)
    }
}
