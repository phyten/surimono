import Foundation
import SurimonoCore

public enum PageLayoutLimits {
    public static let plainTextBytes = DocumentSizeLimits.textBytes
    static let csvRows = 60_000
    static func checkHTML(bytes: Int, sourceBytes: Int) throws {
        guard bytes <= DocumentSizeLimits.htmlBytes else {
            throw DocumentRenderer.RenderingError.tooLarge(bytes: sourceBytes)
        }
    }

    static func timeout(bytes: Int, baseSeconds: Int) -> Duration {
        .seconds(min(300, Double(baseSeconds) + 4 * Double(bytes) / 1_000_000))
    }
}
