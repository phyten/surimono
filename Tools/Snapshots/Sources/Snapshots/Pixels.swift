import Foundation

struct Raster {
    let width, height: Int
    var bytes: [UInt8]  // Opaque sRGB in top-to-bottom RGBA order.
    init(width: Int, height: Int, bytes: [UInt8]) throws {
        guard width > 0, height > 0, width <= 20000, height <= 20000,
            width * height <= 60_000_000, bytes.count == width * height * 4
        else { throw SnapshotError("Invalid or oversized raster: \(width) × \(height)") }
        self.width = width
        self.height = height
        self.bytes = bytes
    }
    func channel(_ x: Int, _ y: Int, _ c: Int) -> Int {
        guard x < width, y < height else { return 255 }
        return Int(bytes[4 * (width * y + x) + c])
    }
}
struct Region: Codable, Equatable {
    var x, y, width, height: Int
    func union(_ b: Self) -> Self {
        let left = min(x, b.x)
        let top = min(y, b.y)
        return Self(
            x: left, y: top, width: max(x + width, b.x + b.width) - left, height: max(y + height, b.y + b.height) - top)
    }
}
struct PixelMetrics: Codable {
    let different: Int
    let ratio: Double
    let maxLuminance: Double
    let dimensionsChanged: Bool
    let anyDifference: Bool
    let regions: [Region]
}

func diffPixels(_ a: Raster, _ b: Raster, _ t: Tolerance) throws -> (PixelMetrics, Raster) {
    let w = max(a.width, b.width)
    let h = max(a.height, b.height)
    guard w * h <= 60_000_000 else { throw SnapshotError("Comparison canvas too large") }
    let cols = (w + t.tile - 1) / t.tile
    let rows = (h + t.tile - 1) / t.tile
    var boxes: [Region?] = Array(repeating: nil, count: cols * rows)
    var sums = [Int](repeating: 0, count: boxes.count)
    var overlay = [UInt8](repeating: 255, count: w * h * 4)
    var count = 0
    var anyDifference = false
    for y in 0..<h {
        for x in 0..<w {
            let i = 4 * (y * w + x)
            let tile = (y / t.tile) * cols + x / t.tile
            let r = b.channel(x, y, 0)
            let g = b.channel(x, y, 1)
            let blue = b.channel(x, y, 2)
            let dr = r - a.channel(x, y, 0)
            let dg = g - a.channel(x, y, 1)
            let db = blue - a.channel(x, y, 2)
            let delta = max(abs(dr), abs(dg), abs(db))
            sums[tile] += 54 * dr + 183 * dg + 19 * db
            if delta != 0 { anyDifference = true }
            if delta > t.channel {
                count += 1
                let pixel = Region(x: x, y: y, width: 1, height: 1)
                boxes[tile] = boxes[tile]?.union(pixel) ?? pixel
                overlay[i] = 255
                overlay[i + 1] = UInt8(g / 3)
                overlay[i + 2] = UInt8(blue / 2)
            } else {
                overlay[i] = UInt8(r)
                overlay[i + 1] = UInt8(g)
                overlay[i + 2] = UInt8(blue)
            }
        }
    }
    var maximum = 0.0
    for (i, sum) in sums.enumerated() {
        let area = min(t.tile, w - i % cols * t.tile) * min(t.tile, h - i / cols * t.tile)
        maximum = max(maximum, Double(abs(sum)) / Double(256 * area))
    }
    // Coalesce touching changed tiles; each returned box uses actual changed pixel bounds.
    var regions: [Region] = []
    for first in boxes.indices {
        guard var box = boxes[first] else { continue }
        boxes[first] = nil
        var stack = [first]
        while let i = stack.popLast() {
            let x = i % cols
            let y = i / cols
            for ny in max(0, y - 1)...min(rows - 1, y + 1) {
                for nx in max(0, x - 1)...min(cols - 1, x + 1) {
                    let j = ny * cols + nx
                    if let next = boxes[j] {
                        boxes[j] = nil
                        box = box.union(next)
                        stack.append(j)
                    }
                }
            }
        }
        regions.append(box)
    }
    let metrics = PixelMetrics(
        different: count, ratio: Double(count) / Double(w * h), maxLuminance: maximum,
        dimensionsChanged: a.width != b.width || a.height != b.height, anyDifference: anyDifference, regions: regions)
    return (metrics, try Raster(width: w, height: h, bytes: overlay))
}
