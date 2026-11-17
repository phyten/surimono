import AppKit
import SurimonoCore

/// Surface commands never acquire a menu equivalent: a bare key must not become window-wide through AppKit.
enum ShortcutSurfaceKeys {
    static let paper: Set<ShortcutOperationID> = [
        .readingBack, .readingForward, .bookmarkToggle, .bookmarkNext, .bookmarkPrevious,
        .viewToolbarToggle, .viewOptions, .viewSelectText, .readingLeft, .readingRight,
        .readingPrevious, .readingNext, .readingPageUp, .readingPageDown, .readingFirst, .readingLast,
    ]
    static let operations = paper.union([.listRemove, .foldLeft, .foldRight])

    static func match(
        _ event: NSEvent, region: ShortcutRegion, controller: ShortcutController
    ) -> ShortcutOperationID? {
        guard let key = ShortcutDispatcher.combination(event, allowsBareKeys: true) else { return nil }
        let matches = operations.filter {
            ShortcutOperation.operation($0).binding(for: key).regions.contains(region)
                && controller.localKeys(for: $0).contains(key)
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Native text clients and controls win even if they are nested inside a PDF surface.
    static func owner(of responder: NSResponder?) -> (any ShortcutSurface)? {
        if ShortcutDispatcher.isTextInput(responder) || responder is NSControl { return nil }
        var view = responder as? NSView
        while let current = view {
            if let surface = current as? any ShortcutSurface { return surface }
            view = current.superview
        }
        return nil
    }
}

@MainActor
protocol ShortcutSurface: AnyObject {
    var shortcutRegion: ShortcutRegion { get }
    func performShortcut(_ operation: ShortcutOperationID, event: NSEvent)
}
