import Foundation

/// App-wide choices captured when a document opens, before its pages and saved settings are available.
public struct ViewDefaultPreferences: Equatable, Sendable {
    /// Nil keeps the document-specific default.
    public var layout: ViewOptions.Layout?
    /// Nil keeps the document-specific default.
    public var transition: ViewOptions.Transition?
    public var direction: ViewOptions.Direction?
    public var scrollAxis: ViewOptions.ScrollAxis?
    public var showsCoverAlone: Bool?
    public var joinsPages: Bool

    public init(
        layout: ViewOptions.Layout? = nil, transition: ViewOptions.Transition? = nil, joinsPages: Bool = true,
        direction: ViewOptions.Direction? = nil, scrollAxis: ViewOptions.ScrollAxis? = nil, showsCoverAlone: Bool? = nil
    ) {
        self.layout = layout
        self.transition = transition
        self.joinsPages = joinsPages
        self.direction = direction
        self.scrollAxis = scrollAxis
        self.showsCoverAlone = showsCoverAlone
    }
}

extension ViewOptions {
    /// Saved choices win outright. Document constraints and PDF hints win over app-wide defaults.
    public static func resolved(
        for context: ViewDefaultsContext, preferences: ViewDefaultPreferences, saved: ViewOptions? = nil
    ) -> ViewOptions {
        if let saved { return saved }
        var result = defaults(for: context)
        let hasPDFLayout =
            context.kind == .pdf
            && [
                "SinglePage", "OneColumn", "TwoColumnLeft", "TwoColumnRight", "TwoPageLeft", "TwoPageRight",
            ].contains(context.pdfPageLayout ?? "")
        let forcesSingle =
            context.kind == .image
            || (context.kind == .pdf && !hasPDFLayout
                && (context.pageCount <= 2 || context.firstPageSize.width > context.firstPageSize.height))
        if !hasPDFLayout {
            if !forcesSingle, let layout = preferences.layout { result.layout = layout }
            if let transition = preferences.transition { result.transition = transition }
            if let scrollAxis = preferences.scrollAxis { result.scrollAxis = scrollAxis }
            if let showsCoverAlone = preferences.showsCoverAlone { result.showsCoverAlone = showsCoverAlone }
            if context.kind != .pdf || context.pdfDirection == nil, let direction = preferences.direction {
                result.direction = direction
            }
        }
        result.joinsPages = preferences.joinsPages
        return result
    }
}
