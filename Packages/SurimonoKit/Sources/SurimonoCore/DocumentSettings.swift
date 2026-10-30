import CoreGraphics
import Foundation

/// Settings remembered for one document, keyed by the hash of its content rather than its name. Every field is
/// optional: an absent field falls back to the current default, and records written by another version still decode.
public struct DocumentSettings: Codable, Equatable, Sendable {
    public struct SmartRemoval: Codable, Equatable, Sendable {
        public var isEnabled: Bool
        /// Detected parts the user chose to keep, by their stable identifiers.
        public var keptIDs: [String]

        public init(isEnabled: Bool, keptIDs: [String] = []) {
            self.isEnabled = isEnabled
            self.keptIDs = keptIDs
        }

        private enum CodingKeys: String, CodingKey { case isEnabled, keptIDs }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
            keptIDs = try values.decodeIfPresent([String].self, forKey: .keptIDs) ?? []
        }
    }

    public var view: ViewOptions?
    /// Magnification relative to fitting the current page or spread into the window.
    public var zoom: Double?
    /// The view mode's content size in points.
    public var windowSize: CGSize?
    public var layoutID: String?
    public var paperOrientation: PaperOrientation?
    public var themeID: String?
    public var textScale: Double?
    public var presetID: String?
    public var smartRemoval: SmartRemoval?
    public var printOptions: PrintOptions?
    /// SHA-256 digests (lowercase hex) of the images in their display order.
    public var imageOrder: [String]?
    /// Whether an HTML document shows as a live web page or as paper.
    public var htmlPresentation: HTMLPresentation?
    /// The reader said the live page is not a slide deck, although it looks like one.
    public var ignoresSlides: Bool?

    public init(
        view: ViewOptions? = nil, zoom: Double? = nil, windowSize: CGSize? = nil, layoutID: String? = nil,
        themeID: String? = nil, textScale: Double? = nil, presetID: String? = nil, smartRemoval: SmartRemoval? = nil,
        printOptions: PrintOptions? = nil, imageOrder: [String]? = nil, paperOrientation: PaperOrientation? = nil,
        htmlPresentation: HTMLPresentation? = nil, ignoresSlides: Bool? = nil
    ) {
        self.view = view
        self.zoom = zoom
        self.windowSize = windowSize
        self.layoutID = layoutID
        self.paperOrientation = paperOrientation
        self.themeID = themeID
        self.textScale = textScale
        self.presetID = presetID
        self.smartRemoval = smartRemoval
        self.printOptions = printOptions
        self.imageOrder = imageOrder
        self.htmlPresentation = htmlPresentation
        self.ignoresSlides = ignoresSlides
    }

    private enum CodingKeys: String, CodingKey {
        case view, zoom, windowSize, paperOrientation, layoutID, themeID, textScale, presetID, smartRemoval,
            printOptions, imageOrder
        case htmlPresentation, ignoresSlides
    }

    /// Decodes each field on its own, so a value this version cannot read (such as a transition added later) falls
    /// back to the default instead of discarding the rest of the record.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func field<Value: Decodable>(_ type: Value.Type, _ key: CodingKeys) -> Value? {
            try? values.decodeIfPresent(type, forKey: key)
        }
        view = field(ViewOptions.self, .view)
        zoom = field(Double.self, .zoom)
        windowSize = field(CGSize.self, .windowSize)
        layoutID = field(String.self, .layoutID)
        paperOrientation = field(PaperOrientation.self, .paperOrientation)
        themeID = field(String.self, .themeID)
        textScale = field(Double.self, .textScale)
        presetID = field(String.self, .presetID)
        smartRemoval = field(SmartRemoval.self, .smartRemoval)
        printOptions = field(PrintOptions.self, .printOptions)
        imageOrder = field([String].self, .imageOrder)
        htmlPresentation = field(HTMLPresentation.self, .htmlPresentation)
        ignoresSlides = field(Bool.self, .ignoresSlides)
    }
}

public enum ImageOrder {
    /// Restores a saved order by image content, so renamed or moved copies keep their places. Returns nil unless
    /// the saved digests describe exactly the same images, counting duplicates.
    public static func apply<Item>(_ savedOrder: [String], to items: [Item], digest: (Item) -> String) -> [Item]? {
        guard savedOrder.count == items.count else { return nil }
        var waiting: [String: [Item]] = [:]
        for item in items { waiting[digest(item), default: []].append(item) }
        var ordered: [Item] = []
        ordered.reserveCapacity(items.count)
        for key in savedOrder {
            guard var candidates = waiting[key], !candidates.isEmpty else { return nil }
            // Identical images keep their current relative order.
            ordered.append(candidates.removeFirst())
            waiting[key] = candidates
        }
        return ordered
    }
}
