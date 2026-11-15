import CoreGraphics

/// How the labels under a printed side share its width: the front or back tag at the leading edge, and a label under
/// each page slot. At a small zoom, or in a language with long words, they no longer fit side by side; rather than lay
/// them over one another, the caption gives way in this order:
///
/// 1. The page label ("Page 1") stays whole.
/// 2. The tag takes its short form (F / B), and only where even that leaves no room for a page label, goes; the side's
///    VoiceOver text still says which side it is.
/// 3. A long note in the first slot, such as "Blank (Back Cover)", loses its end.
struct TrayCaptionFit: Equatable {
    enum Face: Equatable {
        case full, short, hidden
    }

    let face: Face
    /// The room the tag takes at the leading edge, its gap included; 0 without a tag.
    let tagSpace: CGFloat

    /// Between the tag and the label after it.
    static let gap: CGFloat = 4
    /// At either end of a slot's label.
    static let padding: CGFloat = 4

    /// - Parameters:
    ///   - sideWidth: The width of the printed side, which the caption is as wide as.
    ///   - slotCount: The page slots side by side under it; each label has an equal share.
    ///   - faceFull: The tag in its full form, or nil for a side without one.
    ///   - faceShort: The tag in its short form.
    ///   - firstLabel: The label of the first slot, beside the tag.
    ///   - firstIsPage: Whether that label is a page's, which must stay whole, rather than a note that may be cut.
    ///   - centered: Whether the first label is centered on the whole side (stacked slots), so the tag takes room on
    ///     both sides of it.
    init(
        sideWidth: CGFloat, slotCount: Int, faceFull: CGFloat?, faceShort: CGFloat?, firstLabel: CGFloat,
        firstIsPage: Bool, centered: Bool = false
    ) {
        guard let faceFull else {
            face = .full
            tagSpace = 0
            return
        }
        let slot = sideWidth / CGFloat(max(slotCount, 1))
        func fits(_ tag: CGFloat) -> Bool {
            let space = tag + Self.gap
            let room = centered ? slot - 2 * space : slot - space - Self.padding
            return firstLabel <= room
        }
        if fits(faceFull) {
            face = .full
            tagSpace = faceFull + Self.gap
        } else if let faceShort, fits(faceShort) || !firstIsPage {
            face = .short
            tagSpace = faceShort + Self.gap
        } else {
            face = .hidden
            tagSpace = 0
        }
    }
}
