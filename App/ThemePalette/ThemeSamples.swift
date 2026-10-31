import Observation
import PDFKit
import SurimonoCore
import SurimonoRendering

/// The first page of the window's document in each theme, drawn on demand for the style palette and the comparison
/// stage. The samples follow the document and its layout, margins and text size; a change to any of them starts over.
@Observable
final class ThemeSamples {
    /// Counts the fresh starts, so that the samples on screen ask to be drawn again after one.
    private(set) var generation = 0
    /// The paper the samples stand for and its margins, in points.
    private(set) var paperSize = PaperSize.a4.size
    private(set) var margins = WebPaginator.Margins.uniform(millimeters: 15)
    /// What the samples are drawn from; the window's model provides it.
    @ObservationIgnored var inputs: () -> (source: DocumentSource?, settings: RenderSettings?) = { (nil, nil) }
    /// The samples drawn so far, by theme id, with the theme as drawn.
    private var samples: [String: (theme: PrintTheme, page: PDFPage)] = [:]
    @ObservationIgnored private var sampler: ThemeSampler?
    @ObservationIgnored private var key: Key?

    /// What the samples depend on: everything that lays out the page except the theme.
    private struct Key: Equatable {
        let source: DocumentSource
        let settings: RenderSettings
    }

    /// Identifies a sample's drawing in a view's task, so that a fresh start or an edited theme draws it again.
    struct TaskID: Equatable {
        let generation: Int
        let theme: PrintTheme
    }

    func taskID(for theme: PrintTheme) -> TaskID { TaskID(generation: generation, theme: theme) }

    /// The sample of `theme` as it is now; a sample of an earlier version of the theme does not count.
    func page(for theme: PrintTheme) -> PDFPage? {
        guard let sample = samples[theme.id], sample.theme == theme else { return nil }
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
        sampler = try? DocumentRenderer.themeSampler(for: source, settings: settings)
        if let sampler {
            paperSize = sampler.pageSize
            margins = sampler.margins
        }
        if replacesSamples { generation += 1 }
    }

    /// Draws the sample of `theme` unless it is there already. A failed sample stays a blank sheet.
    func load(_ theme: PrintTheme) async {
        refresh()
        guard page(for: theme) == nil, let sampler else { return }
        guard let page = try? await sampler.firstPage(for: theme), sampler === self.sampler else { return }
        samples[theme.id] = (theme, page)
    }

    /// Forgets every sample, for example after the file or a user style changed outside the app; the samples on
    /// screen are drawn again from the new state.
    func invalidate() {
        sampler?.close()
        sampler = nil
        key = nil
        samples = [:]
        generation += 1
    }
}
