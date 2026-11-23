import CoreGraphics

/// A tile owns the surrounding half-gaps, so pointing between two images is also a valid drop.
public struct PageGridInsertion: Equatable, Sendable {
    public let after: Bool
    public let line: CGRect

    public init(point: CGPoint, tile: CGSize, columns: Int, rightToLeft: Bool) {
        if columns == 1 {
            after = point.y >= tile.height / 2
            let y = after ? tile.height : 0
            line = CGRect(x: 0, y: y - 1, width: tile.width, height: 2)
        } else {
            let right = point.x >= tile.width / 2
            after = right != rightToLeft
            let x = right ? tile.width : 0
            line = CGRect(x: x - 1, y: 0, width: 2, height: tile.height)
        }
    }
}

/// The two readable neighbors identify a gap even if the full bundle contains unreadable images.
public struct PageGridGap<Item: Equatable & Sendable>: Sendable {
    private let previous: Item?
    public let anchor: Item?

    public init(readable: [Item], page: Int, after: Bool) {
        let boundary = readable.indices.contains(page) ? page + (after ? 1 : 0) : -1
        previous = readable.indices.contains(boundary - 1) ? readable[boundary - 1] : nil
        anchor = readable.indices.contains(boundary) ? readable[boundary] : nil
    }

    public func moving(_ source: Item, in items: [Item]) -> [Item] {
        guard previous != nil || anchor != nil, source != previous, source != anchor,
            let from = items.firstIndex(of: source)
        else { return items }
        var result = items
        result.remove(at: from)
        if let anchor {
            // A drop can finish after the bundle changed. Never reinterpret a missing anchor as the end.
            guard let index = result.firstIndex(of: anchor) else { return items }
            result.insert(source, at: index)
        } else {
            result.append(source)
        }
        return result
    }
}
