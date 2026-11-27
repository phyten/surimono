import Foundation

/// A wider WKPrintingView clip with the same content columns, Float scale and page height.
struct PrintFrameExtension {
    let width: Float
    let padding: Float
    let minimumWidth: Float

    static func columns(_ width: Float) -> Float {
        floor(width * Float(WebPaginator.printPixelsPerPoint))
    }

    private static func limit(_ columns: Float) -> Float {
        floor(columns * (2 / Float(WebPaginator.printPixelsPerPoint)))
    }

    static func fitted(_ columns: Float, scrollWidth: Float) -> Float {
        min(max(columns, scrollWidth), limit(columns))
    }

    static func calculate(width: Float, height: Float, firstScroll: Float, fittedScroll: Float) -> Self? {
        let initial = columns(width)
        guard initial.isFinite, initial > 0, height.isFinite, height > 0, firstScroll.isFinite, fittedScroll.isFinite
        else { return nil }
        let layout = fitted(initial, scrollWidth: firstScroll)
        let isWide = layout > initial
        let capped = isWide && layout == limit(initial)
        let scale = width / layout
        let rows = floor(layout * (height / width))
        // At the shrink limit, five initial columns buy eight fitted columns. Below it,
        // leave space for any table margin that still overflows WebKit's second layout.
        let extra = capped ? 8 : 2 + max(0, fittedScroll - layout)
        // A third column can represent the original scale when two cannot (e.g. across 512 pt).
        for padding in capped ? [extra] : [extra, extra + 1] {
            let target = layout + padding
            let candidate = target * scale
            for extended in [candidate, candidate.nextDown, candidate.nextUp] where extended > width {
                let newInitial = columns(extended)
                let minimum = isWide ? target : 0
                guard !capped || newInitial == initial + 5,
                    fitted(newInitial, scrollWidth: minimum) == target,
                    extended / target == scale,
                    floor(target * (height / extended)) == rows
                else { continue }
                return Self(width: extended, padding: padding, minimumWidth: minimum)
            }
        }
        return nil
    }
}
