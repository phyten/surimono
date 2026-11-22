import CoreGraphics
import Foundation

/// The rendered SVG and its bounds in a logical PDF page's coordinate system.
public struct RenderedDiagram: Equatable, Sendable {
    public var number: Int
    public var pageIndex: Int
    public var rect: CGRect
    public let formulaSource: String?
    public let svg: String
    /// A tall diagram can have several page rectangles, but every one exports the whole diagram.
    public let pointSize: CGSize

    public init(
        number: Int, pageIndex: Int, rect: CGRect, svg: String, pointSize: CGSize? = nil, formulaSource: String? = nil
    ) {
        self.formulaSource = formulaSource
        self.number = number
        self.pageIndex = pageIndex
        self.rect = rect
        self.svg = svg
        self.pointSize = pointSize ?? rect.size
    }

    public static func hitTest(_ point: CGPoint, pageIndex: Int, in diagrams: [Self]) -> Self? {
        diagrams.first { $0.pageIndex == pageIndex && $0.rect.contains(point) }
    }

    public func suggestedName(documentName: String) -> String {
        let filename = (documentName as NSString).lastPathComponent
        let stem = (filename as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(stem.isEmpty ? "Surimono" : stem)-\(formulaSource == nil ? "diagram" : "formula")-\(number)"
    }
}
