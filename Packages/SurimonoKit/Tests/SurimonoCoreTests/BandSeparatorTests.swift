import Foundation
import SurimonoCore
import Testing

struct BandSeparatorTests {
    @Test("区切りの予約文字列は部品の識別子と衝突せず複数の線をその場で保存する")
    func storedToken() throws {
        #expect(BandEntry.separatorToken == "@separator")
        #expect(BandLayout.Item.allCases.allSatisfy { !$0.rawValue.hasPrefix("@") })
        let wire = StoredBandArrangement(
            topLeft: ["@separator", "style", "future", "@separator", "@separator", "outline", "@separator"],
            topRight: ["print"], unused: ["@separator"])
        let repaired = BandArrangementRepair.repair(wire, for: .split)
        #expect(
            repaired.stored.topLeft == [
                "@separator", "style", "future", "@separator", "@separator", "outline", "@separator",
            ])
        #expect(!repaired.stored.unused.contains("@separator"))
        #expect(repaired.notices.contains(.removedUnusedSeparator))
        #expect(
            repaired.arrangement.topLeft == [
                .separator, .part(.style), .separator, .separator, .part(.outline), .separator,
            ])
        let again = BandArrangementRepair.repair(repaired.stored, for: .split)
        #expect(again.arrangement == repaired.arrangement && again.stored == repaired.stored)
        let decoded = try JSONDecoder().decode(BandArrangement.self, from: JSONEncoder().encode(repaired.arrangement))
        #expect(decoded == repaired.arrangement)
    }

    @Test("区切りのない旧記録も自動で線を足さずに読み込む")
    func olderRecord() {
        let repaired = BandArrangementRepair.repair(
            StoredBandArrangement(topLeft: ["style", "outline"], topRight: ["print"]), for: .split)
        #expect(repaired.arrangement.topLeft == [.part(.style), .part(.outline)])
        #expect(repaired.stored.topLeft == ["style", "outline"])
    }

    @Test("区切りを挿入しても部品の移動は隣の区切りを連れていかない")
    func partMove() throws {
        let initial = BandArrangementRepair.repair(
            StoredBandArrangement(topLeft: ["style", "outline"], topRight: ["print"]), for: .split
        ).arrangement
        let inserted = try initial.insertingSeparator(at: 1, in: .topLeft, for: .split)
        #expect(inserted.topLeft == [.part(.style), .separator, .part(.outline)])
        let moved = try inserted.moving(.style, to: .zone(.topRight), for: .split)
        #expect(moved.topLeft == [.separator, .part(.outline)])
        #expect(moved.topRight == [.part(.print), .part(.style)])
        let removed = try moved.removingSeparator(at: 0, in: .topLeft, for: .split)
        #expect(removed.topLeft == [.part(.outline)])
    }

    @Test("位置による移動は削除前の挿入位置を受け取り区切りを使わないへ移すと消す")
    func entryMove() throws {
        let initial = BandArrangementRepair.repair(
            StoredBandArrangement(topLeft: ["style", "@separator", "outline"], topRight: ["print"]), for: .split
        ).arrangement
        let later = try initial.movingEntry(at: 0, from: .zone(.topLeft), to: .zone(.topLeft), at: 3, for: .split)
        #expect(later.topLeft == [.separator, .part(.outline), .part(.style)])
        let across = try later.movingEntry(at: 0, from: .zone(.topLeft), to: .zone(.topRight), at: 0, for: .split)
        #expect(across.topLeft == [.part(.outline), .part(.style)])
        #expect(across.topRight == [.separator, .part(.print)])
        let deleted = try across.movingEntry(at: 0, from: .zone(.topRight), to: .unused, at: 0, for: .split)
        #expect(deleted.topRight == [.part(.print)])
        #expect(
            deleted.unused == [
                .formatBadge, .pageIndicator, .presentation, .layout, .transition, .zoom, .thumbnails, .floatOnTop,
                .showOnAllSpaces, .pageTurn,
            ] + BandLayoutTests.addedItems + [.chapter])
        #expect(
            try initial.movingEntry(at: 1, from: .zone(.topLeft), to: .zone(.topLeft), at: 1, for: .split) == initial)
        #expect(
            try initial.movingEntry(at: 1, from: .zone(.topLeft), to: .zone(.topLeft), at: 2, for: .split) == initial)
    }

    @Test("区切り編集は範囲外と部品の削除と上だけの下領域と印刷の除外を拒否する")
    func invalidEdits() {
        let layout = BandArrangement.standard(for: .top)
        #expect(throws: BandArrangementMoveError.invalidIndex) {
            try layout.insertingSeparator(at: -1, in: .topLeft, for: .top)
        }
        #expect(throws: BandArrangementMoveError.invalidIndex) {
            try layout.removingSeparator(at: 3, in: .topLeft, for: .top)
        }
        #expect(throws: BandArrangementMoveError.notSeparator) {
            try layout.removingSeparator(at: 0, in: .topLeft, for: .top)
        }
        #expect(throws: BandArrangementMoveError.invalidDestination) {
            try layout.insertingSeparator(at: 0, in: .bottomLeft, for: .top)
        }
        #expect(throws: BandArrangementMoveError.printIsRequired) {
            try layout.movingEntry(at: 12, from: .zone(.topRight), to: .unused, at: 0, for: .top)
        }
    }

    @Test("区切りの前後へ部品を戻せて区切り自身も同じ領域の両方向へ移せる")
    func movesAroundSeparator() throws {
        let initial = BandArrangementRepair.repair(
            StoredBandArrangement(topLeft: ["style", "@separator", "outline"], topRight: ["print"]), for: .split
        ).arrangement
        let later = try initial.movingEntry(at: 1, from: .zone(.topLeft), to: .zone(.topLeft), at: 3, for: .split)
        #expect(later.topLeft == [.part(.style), .part(.outline), .separator])
        let earlier = try later.movingEntry(at: 2, from: .zone(.topLeft), to: .zone(.topLeft), at: 0, for: .split)
        #expect(earlier.topLeft == [.separator, .part(.style), .part(.outline)])
        let unused = try initial.moving(.style, to: .unused, for: .split)
        let restored = try unused.movingEntry(
            at: unused.unused.count - 1, from: .unused, to: .zone(.topLeft), at: 0, for: .split)
        #expect(restored.topLeft == [.part(.style), .separator, .part(.outline)])
        #expect(restored == initial)
        #expect(throws: BandArrangementMoveError.invalidIndex) {
            try initial.movingEntry(at: 3, from: .zone(.topLeft), to: .zone(.topRight), at: 0, for: .split)
        }
        #expect(throws: BandArrangementMoveError.invalidIndex) {
            try initial.movingEntry(at: 1, from: .zone(.topLeft), to: .zone(.topRight), at: 2, for: .split)
        }
    }

    @Test("未知の識別子を挟んだ区切り編集でも未知の並びを保つ")
    func unknownEditing() throws {
        let initial = BandArrangementRepair.repair(
            StoredBandArrangement(topLeft: ["future", "style", "future2", "outline"], topRight: ["print"]), for: .split
        ).arrangement
        let inserted = try initial.insertingSeparator(at: 1, in: .topLeft, for: .split)
        #expect(StoredBandArrangement(inserted).topLeft == ["future", "style", "future2", "@separator", "outline"])
        let removed = try inserted.removingSeparator(at: 1, in: .topLeft, for: .split)
        #expect(StoredBandArrangement(removed).topLeft == ["future", "style", "future2", "outline"])
    }
}

extension BandSeparatorTests {
    @Test("標準と旧目次設定の保存配列には従来の群の間だけ区切りがある")
    func standardEntries() {
        let split = StoredBandArrangement(BandArrangement.standard(for: .split))
        let top = StoredBandArrangement(BandArrangement.standard(for: .top))
        #expect(split.topLeft == ["formatBadge"])
        #expect(split.topRight == ["floatOnTop", "print"])
        #expect(
            split.bottomLeft == [
                "presentation", "@separator", "style", "outline", "@separator", "layout", "transition", "@separator",
                "zoom", "thumbnails",
            ])
        #expect(split.bottomRight == ["chapter", "pageIndicator", "pageTurn"])
        #expect(top.topLeft == ["formatBadge", "pageIndicator", "chapter"])
        #expect(
            top.topRight == [
                "presentation", "@separator", "style", "outline", "@separator", "layout", "transition", "@separator",
                "zoom", "thumbnails", "@separator", "floatOnTop", "print",
            ])
        let migrated = BandArrangementStore.previousArrangement(named: "Previous").activeLayouts
        #expect(
            StoredBandArrangement(migrated.split).bottomLeft == [
                "presentation", "@separator", "style", "@separator", "layout", "transition", "@separator", "zoom",
                "thumbnails",
            ])
        #expect(
            StoredBandArrangement(migrated.top).topRight == [
                "presentation", "@separator", "style", "@separator", "layout", "transition", "@separator", "zoom",
                "thumbnails", "@separator", "floatOnTop", "print",
            ])
    }

    @Test("先頭と末尾と連続する区切りは有効な編集データで上だけの下領域は修復される")
    func separatorValidation() {
        var layout = BandArrangement.standard(for: .top)
        layout.bottomLeft = [.separator, .separator]
        #expect(BandArrangementValidation.issues(in: layout, for: .top) == [.bottomZoneInTopOnly(.bottomLeft)])
        #expect(throws: BandArrangementMoveError.invalidArrangement([.bottomZoneInTopOnly(.bottomLeft)])) {
            try layout.insertingSeparator(at: 0, in: .topLeft, for: .top)
        }
        let repaired = BandArrangementRepair.repair(StoredBandArrangement(layout), for: .top)
        #expect(
            repaired.arrangement.topLeft == [
                .part(.formatBadge), .part(.pageIndicator), .part(.chapter), .separator, .separator,
            ])
        #expect(repaired.arrangement.bottomLeft == [])
        #expect(BandArrangementValidation.issues(in: repaired.arrangement, for: .top) == [])
        #expect(BandArrangementRepair.repair(repaired.stored, for: .top).arrangement == repaired.arrangement)
    }

    private func plan(
        _ entries: [BandEntry], available: Set<BandLayout.Item> = [.style, .outline, .layout, .print],
        width: CGFloat = 1000
    ) -> BandResolvedPlan {
        BandLayout.resolve(
            arrangement: BandArrangement(entries: [.topRight: [.part(.print)], .bottomLeft: entries]),
            mode: .split, availableItems: available,
            measurements: .init(
                items: [
                    .style: .init(full: 40), .outline: .init(full: 30), .layout: .init(full: 20),
                    .print: .init(full: 34),
                ], name: 0),
            metrics: .init(topFixed: 0, bottomFixed: 0, separator: 9), availableWidth: width)
    }

    @Test("同じ群にも線を置けるが先頭末尾と連続する線は幅を増やさない")
    func normalizeVisibleSeparators() {
        let result = plan([.separator, .part(.style), .separator, .separator, .part(.outline), .separator])
        #expect(result.bottom?.leading == [.style, .outline])
        #expect(result.bottom?.geometry.separatorsBefore == [.outline])
        #expect(result.bottom?.geometry.gapsBefore == [.style: 0, .outline: 8])
        #expect(result.bottom?.geometry.separatorWidth == 9)
        #expect(result.bottom?.requiredWidth == 87)
        #expect(result.unusedAvailable == [.layout])
        let bare = plan([.part(.style), .part(.outline)])
        #expect(bare.bottom?.requiredWidth == 78)
        #expect(bare.bottom?.geometry.separatorsBefore == [])
    }

    @Test("使えない部品を除いた両側に部品が残るときだけ線を描く")
    func availability() {
        let entries: [BandEntry] = [.part(.style), .separator, .part(.layout), .separator, .part(.outline)]
        let both = plan(entries, available: [.style, .outline, .print])
        #expect(both.bottom?.geometry.separatorsBefore == [.outline])
        #expect(both.bottom?.requiredWidth == 87)
        let one = plan(entries, available: [.outline, .print])
        #expect(one.bottom?.geometry.separatorsBefore == [])
        #expect(one.bottom?.requiredWidth == 30)
        let empty = plan([.separator, .separator])
        #expect(empty.bottom?.geometry.separatorsBefore == [])
        #expect(empty.bottom?.requiredWidth == 0)
    }

    @Test("区切りの幅も折りたたみに含め最後の片側が消えたら幅から外す")
    func collapseBoundary() {
        let entries: [BandEntry] = [.part(.style), .separator, .part(.outline)]
        let fits = plan(entries, width: 87)
        #expect(fits.bottom?.forms == [.style: .full, .outline: .full])
        #expect(fits.bottom?.requiredWidth == 87)
        let folded = plan(entries, width: 86)
        #expect(folded.bottom?.forms == [.outline: .full])
        #expect(folded.bottom?.geometry.separatorsBefore == [])
        #expect(folded.bottom?.requiredWidth == 30)
        #expect(folded.overflow == [.style])
        #expect(folded.unusedAvailable == [.layout])
        #expect(plan([.part(.style), .part(.outline)], width: 86).bottom?.forms == [.style: .full, .outline: .full])
    }

    @Test("群のない部品と印刷の前にも線を置けるが領域の境界をまたがない")
    func allZones() {
        let result = BandLayout.resolve(
            arrangement: BandArrangement(entries: [
                .topLeft: [.part(.formatBadge), .separator, .part(.pageIndicator)],
                .topRight: [.part(.floatOnTop), .separator, .part(.print), .separator],
                .bottomLeft: [.separator, .part(.style), .separator],
                .bottomRight: [.separator, .part(.outline), .separator, .part(.pageTurn)],
            ]), mode: .split, availableItems: Set(BandLayout.Item.allCases),
            measurements: .init(items: [:], name: 0),
            metrics: .init(topFixed: 0, bottomFixed: 0, separator: 9), availableWidth: 1000)
        #expect(result.top.geometry.separatorsBefore == [.pageIndicator, .print])
        #expect(result.top.geometry.gapsBefore == [.formatBadge: 6, .pageIndicator: 8, .floatOnTop: 0, .print: 8])
        // 6 + 8 + 8 for the gaps, 9 for each line and 8 for the gap the band draws before "…" after the pin.
        #expect(result.top.requiredWidth == 48)
        #expect(result.top.geometry.moreDock == .beforePrint)
        #expect(result.bottom?.geometry.separatorsBefore == [.pageTurn])
        #expect(result.bottom?.requiredWidth == 17)
    }

    @Test("並べ替えた上の帯は「…」の前の隙間も幅に数え、標準の並びと「…」の前に部品がないときは数えない")
    func gapBeforeMore() {
        func top(_ topRight: [BandEntry], left: [BandEntry] = []) -> BandRowPlan {
            BandLayout.resolve(
                arrangement: BandArrangement(entries: [
                    .topLeft: left, .topRight: topRight,
                    .bottomLeft: [], .bottomRight: [],
                ]), mode: .split, availableItems: Set(BandLayout.Item.allCases),
                measurements: .init(items: [:], name: 0),
                metrics: .init(topFixed: 0, bottomFixed: 0, separator: 9), availableWidth: 1000
            ).top
        }
        let reordered = top([.part(.readingDirection), .part(.floatOnTop), .part(.print)])
        #expect(reordered.geometry.moreGap == 8)
        // 8 between the two tools, 10 before the docked Print and 8 before "…".
        #expect(reordered.requiredWidth == 26)
        // Moved to the left, the only tool no longer stands before "…".
        let alone = top([.part(.print)], left: [.part(.readingDirection)])
        #expect(!alone.geometry.usesStandardSpacing && alone.geometry.moreGap == 0)
        #expect(top([.part(.floatOnTop), .part(.print)]).geometry.usesStandardSpacing)
        #expect(top([.part(.floatOnTop), .part(.print)]).geometry.moreGap == 0)
    }
}
