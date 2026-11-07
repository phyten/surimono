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
    }

    private func placeInsertion(at point: CGPoint) {
        guard case .join = plan?.choice, let listFrame, listFrame.contains(point) else {
            insertion = nil
            insertionY = nil
            return
        }
        let frames = rows.map { rowFrames[$0] }
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
