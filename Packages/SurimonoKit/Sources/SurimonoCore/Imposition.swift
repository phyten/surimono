public struct SheetSide: Equatable, Sendable {
    public let slots: [Int?]
    public let isBack: Bool
}

public struct ImpositionPlan: Equatable, Sendable {
    public let sides: [SheetSide]
    public let sheetCount: Int
    public let isDuplex: Bool
    public let logicalPageCount: Int
    public let paper: PaperSize
}

public enum Imposition {
    public static func plan(pageCount: Int, layout: PrintLayout) -> ImpositionPlan {
        let count = max(0, pageCount)
        let duplex = layout.duplex != .none
        var sides: [SheetSide] = []
        func page(_ index: Int) -> Int? { index < count ? index : nil }
        if count > 0 {
            switch layout.kind {
            case .normal:
                for index in 0..<count {
                    sides.append(SheetSide(slots: [index], isBack: duplex && index % 2 == 1))
                }
                if duplex && count % 2 == 1 { sides.append(SheetSide(slots: [nil], isBack: true)) }
            case .twoUp:
                for index in stride(from: 0, to: count, by: 2) {
                    sides.append(SheetSide(slots: [index, page(index + 1)], isBack: false))
                }
            case .booklet:
                let sheets = count / 4 + (count % 4 == 0 ? 0 : 1)
                let padded = sheets * 4
                for sheet in 0..<sheets {
                    sides.append(SheetSide(slots: [page(padded - 2 * sheet - 1), page(2 * sheet)], isBack: false))
                    sides.append(SheetSide(slots: [page(2 * sheet + 1), page(padded - 2 * sheet - 2)], isBack: true))
                }
            }
        }
        return ImpositionPlan(
            sides: sides, sheetCount: duplex ? sides.count / 2 : sides.count, isDuplex: duplex,
            logicalPageCount: count, paper: layout.sheet)
    }
}

public struct PrintSummary: Equatable, Sendable {
    public let logicalPageCount: Int
    public let sheetCount: Int
    public let sideCount: Int
    public let isDuplex: Bool
    public let paper: PaperSize

    public init(plan: ImpositionPlan) {
        logicalPageCount = plan.logicalPageCount
        sheetCount = plan.sheetCount
        sideCount = plan.sides.count
        isDuplex = plan.isDuplex
        paper = plan.paper
    }
}
