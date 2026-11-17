import Foundation

/// Vertical intervals in PDF coordinates; independent of PDFKit and of the page's origin.
struct FootnoteGeometry: Sendable {
    struct Band: Equatable, Sendable {
        let bottom: CGFloat
        let height: CGFloat
    }

    struct Segment: Equatable, Sendable {
        let lower: CGFloat
        let upper: CGFloat
        let shift: CGFloat
    }

    let segments: [Segment]

    init?(lower: CGFloat, upper: CGFloat, bands: [Band]) {
        guard lower.isFinite, upper.isFinite, upper > lower else { return nil }
        var ceiling = upper
        var shift: CGFloat = 0
        var segments: [Segment] = []
        for band in bands.sorted(by: { $0.bottom > $1.bottom }) {
            let top = band.bottom + band.height
            guard band.bottom.isFinite, band.height.isFinite, band.height > 0,
                band.bottom >= lower, top <= ceiling
            else { return nil }
            if top < ceiling { segments.append(Segment(lower: top, upper: ceiling, shift: shift)) }
            ceiling = band.bottom
            shift += band.height
        }
        if ceiling > lower { segments.append(Segment(lower: lower, upper: ceiling, shift: shift)) }
        self.segments = segments
    }

    func shift(at y: CGFloat) -> CGFloat? {
        segments.first { y >= $0.lower && y <= $0.upper }?.shift
    }

    /// The room above the notes for the rule and the air around it.
    static let ruleRoom: CGFloat = 6
    /// How far inside the reserved room the band that is cut out starts and ends.
    static let bandInset: CGFloat = 1.5
    /// What each line's room adds to the height of its notes: the rule's room, both insets and the rounding.
    static let groupRoom: CGFloat = 12

    /// The notes sit on the bottom margin, as in a book; room left over stays between the text and the rule.
    static func noteBottoms(heights: [CGFloat], bottom: CGFloat, reserved: CGFloat) -> [CGFloat]? {
        guard heights.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        var top = bottom + heights.reduce(0, +)
        guard top + ruleRoom <= bottom + reserved else { return nil }
        var result: [CGFloat] = []
        for height in heights {
            top -= height
            result.append(top)
        }
        return result
    }

    static func reservePixels(height: CGFloat, pixelsPerPoint: CGFloat, textScale: Double) -> Int {
        Int(ceil(height * pixelsPerPoint / textScale))
    }
}
