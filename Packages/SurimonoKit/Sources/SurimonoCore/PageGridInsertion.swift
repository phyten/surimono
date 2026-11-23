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
