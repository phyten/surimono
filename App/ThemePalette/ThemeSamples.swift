import Observation
import PDFKit
import SurimonoCore
import SurimonoRendering

/// The first page of the window's document in each theme, drawn on demand for the style palette and the comparison
/// stage, which can also start its pages at a place in the document. The samples follow the document and its layout,
/// margins and text size; a change to any of them starts over.
@Observable
final class ThemeSamples {
    /// Counts the fresh starts, so that the samples on screen ask to be drawn again after one.
    private(set) var generation = 0
    /// The paper the samples stand for and its margins, in points.
    private(set) var paperSize = PaperSize.a4.size
    private(set) var margins = WebPaginator.Margins.uniform(millimeters: 15)
    /// The document has code, so the palette puts the code colors forward.
    private(set) var containsCode = false
    /// The headings and code blocks the samples can start at, once `loadPlaces()` has read them.
    private(set) var places: [SamplePlace] = []
    /// What the samples are drawn from; the window's model provides it.
    @ObservationIgnored var inputs: () -> (source: DocumentSource?, settings: RenderSettings?) = { (nil, nil) }
    /// The samples drawn so far, with the theme as drawn.
    private var samples: [SampleID: (theme: PrintTheme, page: PDFPage)] = [:]
    @ObservationIgnored private var codeSource: DocumentSource?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var sampler: ThemeSampler?
    @ObservationIgnored private var key: Key?
    @ObservationIgnored var diskCache: ThemeSampleCache?
    // Only the bundled specimen opts in; document samples never persist their content.
    @ObservationIgnored var specimenLanguage: (() -> String)?
    func margins(for theme: PrintTheme) -> WebPaginator.Margins { sampler?.margins(for: theme) ?? margins }

    var drawCount: Int { sampler?.drawCount ?? 0 }

    /// What the samples depend on: everything that lays out the page except the theme.
    private struct Key: Equatable {
        let source: DocumentSource
        let settings: RenderSettings
    }

    private struct SampleID: Hashable {
        let themeID: String
        let place: SamplePlace?
    }

    /// Identifies a sample's drawing in a view's task, so that a fresh start or an edited theme draws it again.
    struct TaskID: Equatable {
        let generation: Int
        let theme: PrintTheme
        let place: SamplePlace?
    }

    func taskID(for theme: PrintTheme, at place: SamplePlace? = nil) -> TaskID {
        TaskID(generation: generation, theme: theme, place: place)
    }

    /// The sample of `theme` as it is now; a sample of an earlier version of the theme does not count.
    func page(for theme: PrintTheme, at place: SamplePlace? = nil) -> PDFPage? {
        guard let sample = samples[SampleID(themeID: theme.id, place: place)], sample.theme == theme else { return nil }
        return sample.page
    }

    /// Starts over when the document or its layout changed since the samples were drawn.
    func refresh() {
        let (source, settings) = inputs()
        guard let source, var settings else {
            if key != nil { invalidate() }
            return
        }
        settings.markdownChanges = []
        settings.theme = PrintTheme(id: "", name: "", css: "")
        let key = Key(source: source, settings: settings)
        guard key != self.key else { return }

        // After `invalidate()` the views are already drawing again; a first start needs no new round either.
        let replacesSamples = self.key != nil
        sampler?.close()
        samples = [:]
        self.key = key
        preparation?.cancel()
        sampler = nil
        let removesPaper = WebPaginator.drawsClearPages
        preparation = Task {
            let ready = try? await DocumentRenderer.prepareThemeSampler(
                for: source, settings: settings, removesPaper: removesPaper)
            guard !Task.isCancelled else { return }
            if codeSource != source {
                let hasCode = ready == nil ? false : await Self.hasCode(source)
                guard !Task.isCancelled else { return }
                containsCode = hasCode
                codeSource = source
            }
            sampler = ready
            if let ready {
                paperSize = ready.pageSize
                margins = ready.margins
            }
        }
        if replacesSamples { generation += 1 }
    }

    @concurrent private static func hasCode(_ source: DocumentSource) async -> Bool {
        DocumentRenderer.containsCode(source)
    }

    /// A transient WebKit failure gets one fresh attempt while the requesting view is still present.
    func load(_ theme: PrintTheme, at place: SamplePlace? = nil) async {
        refresh()
        await preparation?.value
        guard !Task.isCancelled else { return }
        guard page(for: theme, at: place) == nil, let sampler, let key else { return }
        let diskKey =
            place == nil
            ? specimenLanguage.map {
                sampler.cacheKey(for: theme, language: $0(), sourceHash: ContentHash.of(key.source.data).hex)
            } : nil
        if let diskKey, let page = diskCache?.page(for: diskKey) {
            samples[SampleID(themeID: theme.id, place: place)] = (theme, page)
            return
        }
        for attempt in 0..<2 {
            do {
                try Task.checkCancellation()
                let page = try await sampler.page(for: theme, at: place)
                try Task.checkCancellation()
                guard sampler === self.sampler else { return }
                if let diskKey { diskCache?.store(page, for: diskKey) }
                samples[SampleID(themeID: theme.id, place: place)] = (theme, page)
                return
            } catch {
                guard !Task.isCancelled, sampler === self.sampler, attempt == 0 else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    /// Reads the places of the document as it is now. False when that did not happen, because the view asking went away
    /// or the document moved on, which says nothing about what places it has.
    @discardableResult
    func loadPlaces() async -> Bool {
        refresh()
        await preparation?.value
        guard !Task.isCancelled else { return false }
        guard let sampler else {
            places = []
            return true
        }
        guard let found = try? await sampler.places(), sampler === self.sampler else { return false }
        places = found
        return true
    }

    /// Forgets every sample, for example after the file or a user style changed outside the app; the samples on
    /// screen are drawn again from the new state.
    func invalidate() {
        preparation?.cancel()
        preparation = nil
        codeSource = nil
        sampler?.close()
        sampler = nil
        key = nil
        samples = [:]
        generation += 1
    }
}
