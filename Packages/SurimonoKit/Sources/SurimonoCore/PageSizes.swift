import Foundation

public enum PageSizes {
    public static func displayed(_ size: CGSize, rotation: Int) -> CGSize {
        rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    public static func matches(_ first: CGSize, _ second: CGSize) -> Bool {
        abs(first.width - second.width) <= 1 && abs(first.height - second.height) <= 1
    }

    public static func representative(_ sizes: [CGSize]) -> CGSize {
        var groups: [(size: CGSize, count: Int)] = []
        for size in sizes where size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 {
            // Compare against the first size so accumulated rounding errors cannot join unrelated sizes.
            if let index = groups.firstIndex(where: { matches($0.size, size) }) {
                groups[index].count += 1
            } else {
                groups.append((size, 1))
            }
        }
        var result = CGSize.zero
        var count = 0
        for group in groups where group.count > count {
            result = group.size
            count = group.count
        }
        return result
    }
}
