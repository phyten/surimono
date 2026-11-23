import Foundation
import SurimonoCore
import Testing

@testable import Surimono

@MainActor
struct BandArrangementPreferencesTests {
    @Test("部品の表示は初めは名前付きで、変更した表示は次の起動にも残る")
    func bandNamesRoundTrip() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        func load() -> AppPreferences { AppPreferences(defaults: suite.defaults, domainName: suite.name) }
        let preferences = load()
        #expect(preferences.bandNames == .shown)
        #expect(suite.defaults.object(forKey: "bandNames") == nil)
        preferences.bandNames = .hidden
        #expect(load().bandNames == .hidden)
        preferences.bandNames = .shown
        #expect(load().bandNames == .shown)
        // Saving a display choice must not create or migrate the arrangement store.
        #expect(suite.defaults.data(forKey: "bandArrangementStore") == nil)
    }

    @Test("保存のない環境は標準が有効で初期化時には何も保存しない")
    func noStoredValue() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let defaults = suite.defaults
        defaults.set("top", forKey: "menuArrangement")
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.bandArrangementStore.active == .standard)
        #expect(preferences.bandArrangementStore.sets == [])
        #expect(
            preferences.bandArrangementStore.activeLayouts.top.topLeft.compactMap(\.item) == [
                .formatBadge, .pageIndicator, .chapter,
            ])
        #expect(
            preferences.bandArrangementStore.activeLayouts.top.unused == [.pageTurn] + BandTestCatalog.standardUnused)
        #expect(preferences.menuArrangement == .top && preferences.showsOutlineOnBand)
        #expect(defaults.object(forKey: "bandArrangementStore") == nil)
    }

    @Test("配置セットと選択中の識別子は再起動後も残り文書や表示の設定を変えない")
    func roundTrip() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let originalMode = preferences.menuArrangement
        let originalLayout = preferences.layoutID
        var layouts = BandArrangementVariants()
        layouts.split = try layouts.split.moving(.print, to: .zone(.bottomLeft), for: .split)
        let set = BandArrangementSet(name: "Reading", layouts: layouts)
        try preferences.saveBandArrangement(set)
        let loaded = AppPreferences(defaults: suite.defaults)
        #expect(loaded.bandArrangementStore.active == .user(set.id))
        #expect(loaded.bandArrangementStore.sets == [set])
        #expect(
            loaded.bandArrangementStore.activeLayouts.split.bottomLeft.compactMap(\.item) == [
                .presentation, .style, .outline, .layout, .zoom, .thumbnails, .print,
            ])
        #expect(loaded.menuArrangement == originalMode && loaded.layoutID == originalLayout)
        #expect(loaded.showsOutlineOnBand)
        let wire = try #require(suite.defaults.data(forKey: "bandArrangementStore"))
        let decoded = try JSONDecoder().decode(BandArrangementStore.self, from: wire)
        #expect(decoded.active == .user(set.id) && decoded.sets == [set])
    }

    @Test("目次を帯に出さない旧設定は読み込みだけでは保存せず両配置で目次を外す")
    func hiddenOutlineMigration() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let defaults = suite.defaults
        defaults.set(false, forKey: "showsOutlineOnBand")
        let preferences = AppPreferences(defaults: defaults)
        let migrated = try #require(preferences.bandArrangementStore.sets.first)
        #expect(preferences.bandArrangementStore.active == .user(migrated.id))
        #expect(
            migrated.layouts.split.bottomLeft.compactMap(\.item) == [
                .presentation, .style, .layout, .transition, .zoom, .thumbnails,
            ])
        #expect(
            migrated.layouts.split.unused == [.showOnAllSpaces] + BandTestCatalog.addedItems + [.outline, .chapter])
        #expect(
            migrated.layouts.top.topRight.compactMap(\.item) == [
                .presentation, .style, .layout, .transition, .zoom, .thumbnails, .floatOnTop, .print,
            ])
        #expect(
            migrated.layouts.top.unused == [.pageTurn] + [.showOnAllSpaces] + BandTestCatalog.addedItems + [
                .outline, .chapter,
            ])
        #expect(!preferences.showsOutlineOnBand)
        #expect(defaults.data(forKey: "bandArrangementStore") == nil)
        #expect(AppPreferences(defaults: suite.defaults).bandArrangementStore.sets.first?.id == migrated.id)
        try preferences.selectBandArrangement(.standard)
        let reloaded = AppPreferences(defaults: suite.defaults)
        #expect(reloaded.bandArrangementStore.active == .standard)
        #expect(reloaded.bandArrangementStore.sets.count == 1)
        #expect(!reloaded.showsOutlineOnBand)
    }

    @Test("使用中の配置を削除するときは代わりの配置を同時に選ぶ")
    func atomicDeleteAndSelect() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let first = BandArrangementSet(name: "First")
        let second = BandArrangementSet(name: "Second")
        try preferences.saveBandArrangement(first)
        try preferences.saveBandArrangement(second, activate: false)
        let before = suite.defaults.data(forKey: "bandArrangementStore")
        #expect(throws: BandArrangementStoreError.replacementRequired) {
            try preferences.deleteBandArrangement(.user(first.id))
        }
        #expect(suite.defaults.data(forKey: "bandArrangementStore") == before)
        #expect(preferences.bandArrangementStore.active == .user(first.id))
        #expect(throws: BandArrangementStoreError.invalidReplacement) {
            try preferences.deleteBandArrangement(.user(first.id), replacement: .user(UUID()))
        }
        #expect(suite.defaults.data(forKey: "bandArrangementStore") == before)
        try preferences.deleteBandArrangement(.user(first.id), replacement: .user(second.id))
        let reloaded = AppPreferences(defaults: suite.defaults)
        #expect(reloaded.bandArrangementStore.active == .user(second.id))
        #expect(reloaded.bandArrangementStore.sets == [second])
        try preferences.selectBandArrangement(.standard)
        try preferences.deleteBandArrangement(.user(second.id))
        #expect(AppPreferences(defaults: suite.defaults).bandArrangementStore.sets == [])
    }

    @Test("標準は上書きも名前変更も削除もできず失敗時は保存しない")
    func standardProtection() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(throws: BandArrangementStoreError.standardIsReadOnly) {
            try preferences.overwriteBandArrangement(.standard, layouts: .init())
        }
        #expect(throws: BandArrangementStoreError.standardIsReadOnly) {
            try preferences.renameBandArrangement(.standard, to: "Other")
        }
        #expect(throws: BandArrangementStoreError.standardIsReadOnly) {
            try preferences.deleteBandArrangement(.standard)
        }
        #expect(suite.defaults.data(forKey: "bandArrangementStore") == nil)
        #expect(preferences.bandArrangementStore.active == .standard)
    }

    @Test("上書きと名前変更は識別子を保ち未保存の値はアプリへ適用しない")
    func overwriteAndDraft() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let preferences = AppPreferences(defaults: suite.defaults)
        let set = BandArrangementSet(name: "Reading")
        try preferences.saveBandArrangement(set)
        var draft = preferences.bandArrangementStore.activeLayouts
        draft.top = try draft.top.moving(.style, to: .unused, for: .top)
        #expect(
            preferences.bandArrangementStore.activeLayouts.top.unused == [.pageTurn] + BandTestCatalog.standardUnused)
        try preferences.overwriteBandArrangement(.user(set.id), layouts: draft)
        try preferences.renameBandArrangement(.user(set.id), to: "  Book  ")
        let reloaded = AppPreferences(defaults: suite.defaults)
        #expect(reloaded.bandArrangementStore.active == .user(set.id))
        #expect(reloaded.bandArrangementStore.sets.first?.name == "Book")
        #expect(
            reloaded.bandArrangementStore.activeLayouts.top.unused == [.pageTurn] + BandTestCatalog.standardUnused + [
                .style
            ])
    }

    @Test("壊れた一件を飛ばして他の配置と未知の部品を残し読み込みでは書き換えない")
    func malformedRecordIsolation() throws {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let data = Data(
            """
            {"schemaVersion":1,"active":{"kind":"user","id":"00000000-0000-0000-0000-000000000002"},"sets":[
              {"id":"00000000-0000-0000-0000-000000000001","name":"First","layouts":{}},
              42,
              {"id":"00000000-0000-0000-0000-000000000002","name":"Second",
               "layouts":{"split":{"topLeft":["future","style"]},"top":false}}
            ]}
            """.utf8)
        suite.defaults.set(data, forKey: "bandArrangementStore")
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.bandArrangementStore.sets.map(\.name) == ["First", "Second"])
        #expect(preferences.bandArrangementNotices.contains(.invalidRecord(1)))
        #expect(preferences.bandArrangementNotices.contains(.recoveredVariant(.top)))
        #expect(preferences.bandArrangementStore.activeLayouts.split.topLeft.compactMap(\.item) == [.style])
        #expect(preferences.bandArrangementStore.activeLayouts.split.topRight.compactMap(\.item) == [.print])
        #expect(suite.defaults.data(forKey: "bandArrangementStore") == data)
        try preferences.selectBandArrangement(.standard)
        let loaded = AppPreferences(defaults: suite.defaults)
        #expect(
            StoredBandArrangement(loaded.bandArrangementStore.sets[1].layouts.split).topLeft == ["future", "style"])
    }

    @Test("将来の形式は元のデータを保持し通常の保存操作で上書きしない")
    func futureEnvelope() {
        let suite = TestDefaultsSuite()
        defer { suite.remove() }
        let data = Data(#"{"schemaVersion":99,"future":{"value":true}}"#.utf8)
        suite.defaults.set(data, forKey: "bandArrangementStore")
        let preferences = AppPreferences(defaults: suite.defaults)
        #expect(preferences.retainedBandArrangementData == data)
        #expect(preferences.bandArrangementStore.active == .standard)
        #expect(preferences.bandArrangementNotices == [.unsupportedSchema(99)])
        #expect(throws: AppPreferences.BandArrangementPersistenceError.self) {
            try preferences.selectBandArrangement(.standard)
        }
        #expect(suite.defaults.data(forKey: "bandArrangementStore") == data)
    }
}
