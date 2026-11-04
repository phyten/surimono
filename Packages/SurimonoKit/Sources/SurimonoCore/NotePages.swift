import Foundation

/// The note pages a document prints with, which belong to the paper rather than to the document's own pages.
public struct NotePages: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var placement: NotePagePlan.Placement
    /// The preset the style came from, built-in or the reader's own. The style stays when that preset is gone.
    public var presetID: String?
    public var style: NotePaperStyle

    public init(
        isEnabled: Bool = false, placement: NotePagePlan.Placement = .spreadRight,
        presetID: String? = NotePaperPreset.standard.id, style: NotePaperStyle = NotePaperPreset.standard.style
    ) {
        self.isEnabled = isEnabled
        self.placement = placement
        self.presetID = presetID
        self.style = style
    }

    /// The 3-up handout has a column for notes of its own and no pages to set beside each other.
    public func applies(to layout: PrintLayout) -> Bool { layout.kind != .handout3 }

    private enum CodingKeys: String, CodingKey { case isEnabled, placement, presetID, style }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Decode fields independently so a future choice cannot discard the reader's other settings.
        self.init(
            isEnabled: (try? values.decode(Bool.self, forKey: .isEnabled)) ?? false,
            placement: (try? values.decode(NotePagePlan.Placement.self, forKey: .placement)) ?? .spreadRight,
            presetID: try? values.decode(String.self, forKey: .presetID),
            style: (try? values.decode(NotePaperStyle.self, forKey: .style)) ?? NotePaperPreset.standard.style)
    }
}

/// A note page the reader saved under a name of their own.
public struct NoteUserPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var style: NotePaperStyle

    public init(id: String = UUID().uuidString, name: String, style: NotePaperStyle) {
        self.id = id
        self.name = name
        self.style = style
    }
}
