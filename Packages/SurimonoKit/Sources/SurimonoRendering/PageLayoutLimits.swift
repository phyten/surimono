import Foundation

public enum PageLayoutLimits {
    public static let plainTextBytes = 30_000_000
    static let csvRows = 60_000
    static func checkHTML(bytes: Int, sourceBytes: Int) throws {
        guard bytes <= 60_000_000 else { throw DocumentRenderer.RenderingError.tooLarge(bytes: sourceBytes) }
    }

    static func timeout(bytes: Int, baseSeconds: Int) -> Duration {
        .seconds(min(300, Double(baseSeconds) + 4 * Double(bytes) / 1_000_000))
    }
}
