import Foundation
import SurimonoCore

/// A trial and the paper underneath can have different line breaks. Each owns the inputs
/// for its own disposable index print, and releases them once the index is ready.
@MainActor
public final class PaperFormulaIndex {
    public private(set) var entries: [RenderedDiagram]?
    private var load: (() async throws -> [RenderedDiagram])?
    private var loading: Task<[RenderedDiagram], any Error>?

    init(source: DocumentSource, settings: RenderSettings, pageCount: Int) {
        load = {
            var indexSettings = settings
            indexSettings.indexesFormulas = true
            let render = try await DocumentRenderer().prepare(source, settings: indexSettings)
            guard render.viewDocument.pageCount == pageCount else { throw WebPaginator.PaginationError.printFailed }
            return render.diagrams.filter { $0.formulaSource != nil }
        }
    }

    public func resolve() async throws -> [RenderedDiagram] {
        if let entries { return entries }
        if let loading { return try await loading.value }
        guard let load else { return [] }
        let task = Task { try await load() }
        loading = task
        defer { loading = nil }
        let result = try await task.value
        entries = result
        self.load = nil
        return result
    }
}
