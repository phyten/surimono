import CoreGraphics
import Foundation
import Observation
import SurimonoCore

/// A file drag over one window: what the window would do with it, and what lies under the pointer.
@Observable
final class DropSession {
    enum Zone: Equatable { case join, open }

    /// The share of the window that joins the files when both are on offer. Opening gets the larger part: most files
    /// dropped on a document are simply meant to open.
    static let joinShare: CGFloat = 0.38
    /// How long a drag rests on the list's button before the list opens.
    static let springDelay: Duration = .milliseconds(500)

    private(set) var plan: DropPlan?
    private(set) var zone: Zone?
    /// The row the files would go in front of; nil puts them at the end.
    private(set) var insertion: Int?
    /// Where the line between the rows goes, for `insertion`.
    private(set) var insertionY: CGFloat?
    /// Two columns have a gap on either side of each thumbnail, including the last visible one.
    @ObservationIgnored var usesPageGrid = false
    private(set) var gridInsertionLine: CGRect?
    var size: CGSize = .zero
    /// The rows of the open list in order, in the window's coordinates.
    @ObservationIgnored var rowFrames: [URL: CGRect] = [:]
    @ObservationIgnored var listFrame: CGRect?
    @ObservationIgnored var listButtonFrame: CGRect?
    /// Opens the list when a drag rests on its button.
    @ObservationIgnored var onSpring: (() -> Void)?
    @ObservationIgnored private var rows: [URL] = []
    @ObservationIgnored private var springTask: Task<Void, Never>?

    var isActive: Bool { plan != nil }
    /// Whether the drag needs the band: only for the list's button, which opens the list when a drag rests on it.
    /// Elsewhere the band would only come and go under the drop's own overlay.
    var holdsBand: Bool { isActive && hasList }
    /// The window shows a list of documents or images, whose button the band carries.
    @ObservationIgnored var hasList = false

    func begin(_ plan: DropPlan, rows: [URL], at point: CGPoint) {
        self.plan = plan
        self.rows = rows
        move(to: point)
    }

    /// Whether dropping here would do something.
    @discardableResult
    func move(to point: CGPoint) -> Bool {
        guard let plan else { return false }
        switch plan.choice {
        case .joinOrOpen:
            zone = size.width > 0 && point.x / size.width < Self.joinShare ? .join : .open
        case .join: zone = .join
        case .open: zone = .open
        case .refuse: zone = nil
        }
        placeInsertion(at: point)
        updateSpring(at: point)
        return zone != nil
    }

    func end() {
        springTask?.cancel()
        springTask = nil
        plan = nil
        zone = nil
        insertion = nil
        insertionY = nil
        gridInsertionLine = nil
    }

    private func placeInsertion(at point: CGPoint) {
        gridInsertionLine = nil
        guard case .join = plan?.choice, let listFrame, listFrame.contains(point) else {
            insertion = nil
            insertionY = nil
            return
        }
        let frames = rows.map { rowFrames[$0] }
        if usesPageGrid {
            let candidates = frames.enumerated().compactMap { index, rect in rect.map { (index, $0) } }
            if let (index, frame) = candidates.min(by: {
                hypot($0.1.midX - point.x, $0.1.midY - point.y) < hypot($1.1.midX - point.x, $1.1.midY - point.y)
            }) {
                let after = point.y > frame.maxY || (point.y >= frame.minY && point.x >= frame.midX)
                insertion = min(index + (after ? 1 : 0), rows.count)
                insertionY = nil
                gridInsertionLine = CGRect(
                    x: after ? frame.maxX : frame.minX, y: frame.minY, width: 2, height: frame.height)
                return
            }
        }
        let gap = Self.insertion(at: point.y, rows: frames)
        insertion = gap.index
        insertionY = gap.y
    }

    /// The gap nearest to `y`. A row the list has not drawn yet keeps its place in the count without a frame.
    static func insertion(at y: CGFloat, rows: [CGRect?]) -> (index: Int?, y: CGFloat?) {
        for (index, frame) in rows.enumerated() {
            guard let frame else { continue }
            if y < frame.midY { return (index, frame.minY) }
        }
        return (nil, rows.compactMap { $0?.maxY }.max())
    }

    private func updateSpring(at point: CGPoint) {
        guard listButtonFrame?.contains(point) == true, zone != nil else {
            springTask?.cancel()
            springTask = nil
            return
        }
        guard springTask == nil else { return }
        springTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.springDelay) } catch { return }
            self?.onSpring?()
        }
    }
}
