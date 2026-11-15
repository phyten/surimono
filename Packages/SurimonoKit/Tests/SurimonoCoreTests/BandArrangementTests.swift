import Foundation
import SurimonoCore
import Testing

struct BandArrangementTests {
    @Test("標準の上下配置は固定済みの四領域と一致する")
    func standardSplit() {
        let layout = BandArrangement.standard(for: .split)
        #expect(
            [
                layout.topLeft.compactMap(\.item), layout.topRight.compactMap(\.item),
                layout.bottomLeft.compactMap(\.item), layout.bottomRight.compactMap(\.item), layout.unused,
            ]
                == BandLayoutTests.standardSplit)
        #expect(BandArrangementValidation.issues(in: layout, for: .split) == [])
    }

    @Test("標準の上だけ配置はページ送りを置かず現在の順と一致する")
    func standardTop() {
        let layout = BandArrangement.standard(for: .top)
        #expect(
            [
                layout.topLeft.compactMap(\.item), layout.topRight.compactMap(\.item),
                layout.bottomLeft.compactMap(\.item), layout.bottomRight.compactMap(\.item), layout.unused,
            ]
                == BandLayoutTests.standardTop)
        #expect(BandArrangementValidation.issues(in: layout, for: .top) == [])
    }

    @Test("同じ領域の後ろへ移すと削除後の位置へ正しく挿入する")
    func moveWithinZone() throws {
        let moved = try BandArrangement.standard(for: .split).moving(
            .style, to: .zone(.bottomLeft), before: .zoom, for: .split)
        #expect(
            moved.bottomLeft.compactMap(\.item) == [
                .presentation, .outline, .layout, .transition, .style, .zoom, .thumbnails,
            ])
        let appended = try moved.moving(.presentation, to: .zone(.bottomLeft), for: .split)
        #expect(
            appended.bottomLeft.compactMap(\.item) == [
                .outline, .layout, .transition, .style, .zoom, .thumbnails, .presentation,
            ])
        let earlier = try appended.moving(.style, to: .zone(.bottomLeft), before: .outline, for: .split)
        #expect(
            earlier.bottomLeft.compactMap(\.item) == [
                .style, .outline, .layout, .transition, .zoom, .thumbnails, .presentation,
            ])
    }

    @Test("自分自身の前への移動は配置を変えない")
    func moveBeforeSelf() throws {
        let layout = BandArrangement.standard(for: .split)
        #expect(try layout.moving(.style, to: .zone(.bottomLeft), before: .style, for: .split) == layout)
    }

    @Test("領域をまたぐ移動と使わない部品への移動は元の位置を空ける")
    func moveAcrossZones() throws {
        let moved = try BandArrangement.standard(for: .split).moving(
            .print, to: .zone(.bottomLeft), before: .style, for: .split)
        #expect(moved.topRight.compactMap(\.item) == [.floatOnTop])
        #expect(
            moved.bottomLeft.compactMap(\.item) == [
                .presentation, .print, .style, .outline, .layout, .transition, .zoom, .thumbnails,
            ])
        #expect(moved.location(of: .print) == .zone(.bottomLeft))
        let unused = try moved.moving(.outline, to: .unused, for: .split)
        #expect(unused.unused == BandLayoutTests.addedItems + [.outline])
        let restored = try unused.moving(.outline, to: .zone(.topLeft), for: .split)
        #expect(restored.topLeft.compactMap(\.item) == [.formatBadge, .outline])
        #expect(restored.unused == BandLayoutTests.addedItems)
    }

    @Test("印刷を使わない部品へ移す操作と無効な行き先を拒否する")
    func invalidMoves() {
        let layout = BandArrangement.standard(for: .top)
        #expect(throws: BandArrangementMoveError.printIsRequired) {
            try layout.moving(.print, to: .unused, for: .top)
        }
        #expect(throws: BandArrangementMoveError.invalidDestination) {
            try layout.moving(.style, to: .zone(.bottomLeft), for: .top)
        }
        #expect(throws: BandArrangementMoveError.invalidSuccessor) {
            try layout.moving(.style, to: .zone(.topLeft), before: .zoom, for: .top)
        }
        #expect(layout.topRight.last == .part(.print))
    }

    @Test("検証は欠落と重複と印刷の除外と上だけの下領域を列挙する")
    func validation() {
        var layout = BandArrangement.standard(for: .top)
        layout.topLeft = [.part(.formatBadge), .part(.formatBadge)]
        layout.topRight.removeAll { $0 == .part(.print) }
        layout.unused.append(.print)
        layout.bottomLeft = [.part(.style)]
        #expect(
            BandArrangementValidation.issues(in: layout, for: .top) == [
                .duplicate(.formatBadge), .missing(.pageIndicator), .duplicate(.style), .printIsUnused,
                .bottomZoneInTopOnly(.bottomLeft),
            ])
    }

    @Test("重複した部品は最初の表示位置だけに残り欠けた印刷は上の右へ復元する")
    func repairDuplicatesAndPrint() {
        let result = BandArrangementRepair.repair(
            StoredBandArrangement(
                topLeft: ["style"], topRight: ["style"], bottomLeft: ["style", "zoom"],
                unused: ["print", "zoom", "outline", "outline"]), for: .split)
        #expect(result.arrangement.topLeft.compactMap(\.item) == [.style])
        #expect(result.arrangement.topRight.compactMap(\.item) == [.print])
        #expect(result.arrangement.bottomLeft.compactMap(\.item) == [.zoom])
        #expect(
            result.arrangement.unused == [
                .outline, .formatBadge, .pageIndicator, .presentation, .layout,
                .transition, .thumbnails, .floatOnTop, .pageTurn,
            ] + BandLayoutTests.addedItems)
        #expect(result.notices.contains(.restoredPrint))
    }

    @Test("追加された部品は既存の並びを変えず両方の使わない部品へ入る", arguments: MenuArrangement.allCases)
    func laterItem(mode: MenuArrangement) {
        var wire = StoredBandArrangement(BandArrangement.standard(for: mode))
        wire.topRight.removeAll { $0 == "floatOnTop" }
        let repaired = BandArrangementRepair.repair(wire, for: mode)
        #expect(
            repaired.arrangement.unused == (mode == .top ? [.pageTurn] : []) + BandLayoutTests.addedItems + [
                .floatOnTop
            ])
        #expect(repaired.stored.topRight == wire.topRight)
        #expect(repaired.notices == [.addedToUnused(.floatOnTop)])
    }

    @Test("未知の部品があっても既知の配置を読み込み生の位置を保存する")
    func unknownRoundTrip() throws {
        let data = Data(#"{"topLeft":["future","style","future2"],"topRight":["print"],"unused":["future3"]}"#.utf8)
        let layout = try JSONDecoder().decode(BandArrangement.self, from: data)
        #expect(layout.topLeft.compactMap(\.item) == [.style])
        #expect(layout.unknownPlacements.map(\.id) == ["future", "future2", "future3"])
        let wire = try JSONDecoder().decode(StoredBandArrangement.self, from: JSONEncoder().encode(layout))
        #expect(wire.topLeft == ["future", "style", "future2"])
        #expect(wire.unused.first == "future3")
        let again = BandArrangementRepair.repair(wire, for: .split)
        #expect(again.arrangement == layout)
    }

    @Test("上だけに保存された下の部品を左右ごとに上へ移す")
    func topRepair() {
        let result = BandArrangementRepair.repair(
            StoredBandArrangement(
                topLeft: ["formatBadge"], topRight: ["print"],
                bottomLeft: ["style", "future"], bottomRight: ["pageTurn"]), for: .top)
        #expect(result.stored.topLeft == ["formatBadge", "style", "future"])
        #expect(result.arrangement.topRight.compactMap(\.item) == [.print, .pageTurn])
        #expect(
            result.arrangement.bottomLeft.compactMap(\.item) == []
                && result.arrangement.bottomRight.compactMap(\.item) == [])
    }

    @Test("配置を二度修復しても結果は変わらない", arguments: MenuArrangement.allCases)
    func idempotence(mode: MenuArrangement) {
        let first = BandArrangementRepair.repair(
            StoredBandArrangement(
                topLeft: ["style", "style", "future"], bottomLeft: ["print", "zoom"],
                bottomRight: ["print"], unused: ["outline", "future2", "print"]), for: mode)
        let second = BandArrangementRepair.repair(first.stored, for: mode)
        #expect(second.arrangement == first.arrangement)
        #expect(second.stored == first.stored)
        #expect(BandArrangementValidation.issues(in: second.arrangement, for: mode) == [])
    }
}
