import Observation
import PDFKit
import SurimonoCore
import SurimonoRendering

/// Trying a theme on the paper while the pointer rests on it in the style palette.
///
/// It lays the whole document out with the theme on its own renderer, so the document's own logical pages and their
/// cache stay as they are, and the paper goes back to them at once. A request waits a moment first, so that sweeping
/// across the palette does not lay out every theme on the way, and a newer request cancels an older one.
@Observable
final class ThemeTrial {
    /// The theme being tried, from the moment the pointer rests on it.
    private(set) var themeID: String?
    /// Its logical pages, once laid out.
    private(set) var document: PDFDocument?
    @ObservationIgnored private let renderer: DocumentRenderer
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Recent trials, so going back to a theme just tried shows it at once.
    @ObservationIgnored private var recent:
        [(source: DocumentSource, settings: RenderSettings, document: PDFDocument)] =
            []
    static let cacheLimit = 6
    static let delay: Duration = .milliseconds(200)

    init(renderer: DocumentRenderer = DocumentRenderer()) {
        self.renderer = renderer
    }

    /// Tries `settings`, whose theme is the one to try.
    /// - Parameter isBusy: Whether the document is being laid out for real; a trial waits for that to finish rather
    ///   than run two layouts at once.
    func begin(source: DocumentSource, settings: RenderSettings, isBusy: @escaping () -> Bool) {
        let id = settings.theme.id
        // The same theme again, loaded or still on its way, needs nothing more.
        guard themeID != id else { return }
        task?.cancel()
        themeID = id
        if let hit = recent.first(where: { $0.source == source && $0.settings == settings }) {
            document = hit.document
            return
        }
        document = nil
        task = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.delay)
                while isBusy() { try await Task.sleep(for: .milliseconds(50)) }
                guard let self else { return }
                let prepared = try await renderer.prepare(source, settings: settings)
                try Task.checkCancellation()
                guard themeID == id else { return }
                document = prepared.logicalDocument
                recent.removeAll { $0.source == source && $0.settings == settings }
                recent.insert((source, settings, prepared.logicalDocument), at: 0)
                if recent.count > Self.cacheLimit { recent.removeLast(recent.count - Self.cacheLimit) }
            } catch {
                // A cancelled or failed trial leaves the paper on the document's own pages.
            }
        }
    }

    /// Stops trying; the paper shows the document's own pages again.
    func end() {
        task?.cancel()
        task = nil
        themeID = nil
        document = nil
    }

    /// Forgets the recent trials, for example after the file changed outside the app.
    func clear() {
        end()
        recent = []
        renderer.clearCache()
    }
}
