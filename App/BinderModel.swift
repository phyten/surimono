import AppKit
import Observation
import PDFKit
import SurimonoCore
import SurimonoRendering
import SwiftUI

@Observable
final class BinderModel {
    /// Where a binder comes from. The same files make a different binder when a parent file names them.
    enum Origin: Equatable {
        case files
        case parent(URL, hasPreface: Bool)
    }

    struct Item: Identifiable, Equatable, Sendable {
        let url: URL
        let format: DocumentFormat
        /// The parent file's own text, without the lines that name the other documents.
        var isPreface = false
        var id: URL { url }
        var name: String {
            isPreface
                ? String(format: String(localized: "%@ (Preface)"), url.lastPathComponent) : url.lastPathComponent
        }
    }

    let origin: Origin
    private(set) var items: [Item] = []
    var selection: URL?
    private(set) var excludedURLs: [URL] = []
    private(set) var unreadableURLs: [URL] = []
    /// What a parent file names but cannot be read, as the parent writes it.
    private(set) var missingPaths: [String] = []
    /// The order a parent file names; a binder without a parent starts in name order.
    private var startingOrder: [URL]?
    private(set) var pageCounts: [URL: Int] = [:]
    private(set) var thumbnails: [URL: NSImage] = [:]
    private var sources: [URL: DocumentSource] = [:]
    private var leases: [URL: FolderAccess.Lease] = [:]
    private var scopedURLs: Set<URL> = []
    private let read: @Sendable (URL) throws -> Data

    init(
        urls: [URL], excluded: [URL] = [], read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.read = read
        origin = .files
        excludedURLs = excluded
        add(urls)
    }

    /// The documents a parent file names, in its order. Only the parent's text changes, and only in memory. The reader
    /// chose the parent and the documents added later, but the parent's text chose its documents, so each read of those
    /// stays under the parent's folder, whatever has been swapped in since the plan was made.
    init(plan: MarkdownIncludes.Plan) {
        let parent = plan.parent
        let root = plan.root
        let named = Set(plan.documents)
        read = { url in
            if url == parent { return MarkdownIncludes.prefaceData(try Data(contentsOf: url)) }
            return named.contains(url) ? try ConfinedFile.read(url, within: root) : try Data(contentsOf: url)
        }
        origin = .parent(parent, hasPreface: plan.hasPreface)
        excludedURLs = plan.excluded
        missingPaths = plan.missing
        if plan.hasPreface { items.append(Item(url: parent, format: .markdown, isPreface: true)) }
        items += plan.documents.compactMap { url in
            OpenRequest.binderFormat(url).map { Item(url: url, format: $0) }
        }
        startingOrder = items.map(\.url)
        selection = items.first?.url
    }

    var cachedSource: DocumentSource? {
        let children = items.compactMap { sources[$0.url] }
        return children.isEmpty ? nil : .binder(children)
    }

    func fileRequiringAccess(_ folder: URL?) -> URL? {
        guard let folder else { return nil }
        return urls.first { $0.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }
    }

    func didFail(_ urls: [URL]) {
        unreadableURLs = Array(Set(unreadableURLs + urls)).sorted { $0.path < $1.path }
        pageCounts = [:]
        thumbnails = [:]
    }

    var urls: [URL] { items.map(\.url) }
    var usesPrintTheme: Bool { items.contains { $0.format.usesPrintTheme } }
    var usesHTMLPreset: Bool { items.contains { $0.format.usesHTMLPreset } }
    var setHash: ContentHash? {
        let hashes = items.compactMap { sources[$0.url]?.contentHash }
        return hashes.count == items.count && !hashes.isEmpty ? .binderSet(hashes) : nil
    }
    var orderDigests: [String]? {
        guard setHash != nil else { return nil }
        return items.compactMap { sources[$0.url]?.contentHash?.hex }
    }
    var isSortedByName: Bool { items == sorted(items) }
    /// Only an order the reader made is worth remembering.
    var isInStartingOrder: Bool { items == startingItems(items) }

    /// The parent's order, or name order without a parent. Documents added later follow by name.
    private func startingItems(_ items: [Item]) -> [Item] {
        guard let startingOrder else { return sorted(items) }
        let named = startingOrder.compactMap { url in items.first { $0.url == url } }
        return named + sorted(items.filter { !startingOrder.contains($0.url) })
    }

    private func sorted(_ items: [Item]) -> [Item] {
        items.sorted {
            let order = NaturalOrder.compare($0.name, $1.name)
            return order == .orderedSame ? $0.url.absoluteString < $1.url.absoluteString : order == .orderedAscending
        }
    }

    func add(_ urls: [URL]) {
        var known = Set(self.urls)
        var added: [Item] = []
        for url in urls.map(\.standardizedFileURL) where known.insert(url).inserted {
            guard let format = OpenRequest.binderFormat(url) else {
                if !excludedURLs.contains(url) { excludedURLs.append(url) }
                continue
            }
            added.append(Item(url: url, format: format))
        }
        items += sorted(added)
        if selection == nil { selection = items.first?.url }
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: offsets, toOffset: destination)
    }

    func moveSelection(by offset: Int) {
        guard let index = items.firstIndex(where: { $0.url == selection }), items.indices.contains(index + offset)
        else { return }
        items.swapAt(index, index + offset)
    }

    func removeSelection() {
        guard let index = items.firstIndex(where: { $0.url == selection }) else { return }
        let url = items.remove(at: index).url
        sources.removeValue(forKey: url)
        pageCounts.removeValue(forKey: url)
        thumbnails.removeValue(forKey: url)
        leases.removeValue(forKey: url)?.close()
        if scopedURLs.remove(url) != nil { url.stopAccessingSecurityScopedResource() }
        selection = items.isEmpty ? nil : items[min(index, items.count - 1)].url
    }

    func sortByName() { items = sorted(items) }

    func resetOrder() { items = startingItems(items) }

    @discardableResult
    func applyOrder(_ digests: [String]) -> Bool {
        guard let ordered = ImageOrder.apply(digests, to: items, digest: { sources[$0.url]?.contentHash?.hex ?? "" })
        else { return false }
        items = ordered
        return true
    }

    func clearCache() {
        sources = [:]
        thumbnails = [:]
        pageCounts = [:]
        for lease in leases.values { lease.close() }
        leases = [:]
    }

    func stop() {
        for lease in leases.values { lease.close() }
        leases = [:]
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs = []
    }

    func source() async throws -> DocumentSource {
        let items = items
        let known = sources
        for item in items {
            if !scopedURLs.contains(item.url), item.url.startAccessingSecurityScopedResource() {
                scopedURLs.insert(item.url)
            }
            if SandboxEnvironment.isSandboxed, leases[item.url] == nil {
                leases[item.url] = FolderAccess.shared.acquire(for: item.url)
            }
        }
        let read = read
        let loading = Task.detached(priority: Task.currentPriority) {
            var loaded: [URL: DocumentSource] = [:]
            for item in items {
                try Task.checkCancellation()
                if let cached = known[item.url] {
                    loaded[item.url] = cached
                } else if let data = try? read(item.url) {
                    loaded[item.url] = DocumentSource(data: data, fileURL: item.url, format: item.format).hashed()
                }
            }
            return loaded
        }
        var loaded = try await withTaskCancellationHandler {
            try await loading.value
        } onCancel: {
            loading.cancel()
        }
        try Task.checkCancellation()
        for item in items { loaded[item.url]?.allowedResourceFolders = leases[item.url].map { [$0.url] } ?? [] }
        sources = loaded
        unreadableURLs = items.filter { loaded[$0.url] == nil }.map(\.url)
        return .binder(items.compactMap { loaded[$0.url] })
    }

    func didRender(_ prepared: PreparedRender) {
        unreadableURLs = Array(Set(unreadableURLs + prepared.unreadableDocumentURLs)).sorted { $0.path < $1.path }
        pageCounts = prepared.binderDocuments.mapValues(\.pageCount)
        thumbnails = prepared.binderDocuments.compactMapValues {
            $0.page(at: 0)?.thumbnail(of: NSSize(width: 96, height: 96), for: .mediaBox)
        }
    }

    func title(language: String) -> String {
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return String(
            format: bundle.localizedString(forKey: "Binder: %@ and %lld more", value: nil, table: nil),
            items.first?.name ?? "", max(0, items.count - 1))
    }

    func exportName(layout: PrintLayout, language: String) -> String {
        "\(title(language: language).replacingOccurrences(of: ":", with: "-"))（\(layout.displayName(language: language))）.pdf"
    }
}
