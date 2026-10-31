import Foundation

/// App-wide choices captured when a document opens, before its pages and saved settings are available.
public struct ViewDefaultPreferences: Equatable, Sendable {
    /// Nil keeps the document-specific default.
    public var layout: ViewOptions.Layout?
    /// Nil keeps the document-specific default.
    public var transition: ViewOptions.Transition?
    public var joinsPages: Bool

    public init(
        layout: ViewOptions.Layout? = nil, transition: ViewOptions.Transition? = nil, joinsPages: Bool = true
    ) {
        self.layout = layout
        self.transition = transition
        self.joinsPages = joinsPages
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
        }
        result.joinsPages = preferences.joinsPages
        return result
    }
}
