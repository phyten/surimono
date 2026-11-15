public struct ManualDuplexCorrection: Codable, Equatable, Sendable {
    public var reversesBackOrder: Bool
    public var rotatesBackSides: Bool

    public init(reversesBackOrder: Bool = false, rotatesBackSides: Bool = false) {
        self.reversesBackOrder = reversesBackOrder
        self.rotatesBackSides = rotatesBackSides
    }

    private enum CodingKeys: String, CodingKey { case reversesBackOrder, rotatesBackSides }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A damaged adjustment must not discard the other, independently useful adjustment.
        reversesBackOrder = (try? values.decode(Bool.self, forKey: .reversesBackOrder)) ?? false
        rotatesBackSides = (try? values.decode(Bool.self, forKey: .rotatesBackSides)) ?? false
    }
}

public struct ManualDuplexSide: Equatable, Sendable {
    public let copyIndex: Int
    public let sheetIndex: Int
    public let sourceSideIndex: Int
    public let isBlank: Bool
    public let rotates180: Bool
}

public struct ManualDuplexPlan: Equatable, Sendable {
    public let fronts: [ManualDuplexSide]
    public let backs: [ManualDuplexSide]
    public let frontPageOrder: PrintPageOrder
    public let sheetCount: Int

    public enum PlanError: Error, Equatable {
        case invalidImposition
        case invalidCopies
        case overflow
    }

    public static func make(
        imposition: ImpositionPlan, copies: Int, frontPageOrder: PrintPageOrder,
        correction: ManualDuplexCorrection
    ) throws -> ManualDuplexPlan {
        guard (1...99).contains(copies) else { throw PlanError.invalidCopies }
        let (sideCount, sideOverflow) = imposition.sheetCount.multipliedReportingOverflow(by: 2)
        let (count, copyOverflow) = imposition.sheetCount.multipliedReportingOverflow(by: copies)
        guard !sideOverflow, !copyOverflow else { throw PlanError.overflow }
        guard imposition.isDuplex, imposition.sheetCount > 0, sideCount == imposition.sides.count,
            imposition.sides.enumerated().allSatisfy({ $0.element.isBack == ($0.offset % 2 == 1) })
        else { throw PlanError.invalidImposition }
        var fronts: [ManualDuplexSide] = []
        var backs: [ManualDuplexSide] = []
        for copy in 0..<copies {
            for sheet in 0..<imposition.sheetCount {
                func side(_ back: Bool) -> ManualDuplexSide {
                    let index = 2 * sheet + (back ? 1 : 0)
                    return ManualDuplexSide(
                        copyIndex: copy, sheetIndex: sheet, sourceSideIndex: index,
                        isBlank: imposition.sides[index].slots.allSatisfy { $0 == nil },
                        rotates180: back && correction.rotatesBackSides)
                }
                fronts.append(side(false))
                backs.append(side(true))
            }
        }
        // The intact stack feeds the last emitted sheet first. Reverse the whole expanded job, not each copy.
        if (frontPageOrder == .firstSheetFirst) != correction.reversesBackOrder { backs.reverse() }
        return ManualDuplexPlan(fronts: fronts, backs: backs, frontPageOrder: frontPageOrder, sheetCount: count)
    }
}
