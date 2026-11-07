import Foundation
import Observation
import SurimonoCore
import SurimonoRendering
import SwiftUI

@Observable
final class ImageBundleModel {
    struct Item: Identifiable, Hashable, Sendable {
        /// The image file, or for an entry of a ZIP archive the archive's URL with the entry path appended. It only
        /// identifies the image; nothing is ever written there.
        let url: URL
        /// The file name, or the path inside the archive.
        let name: String
        var id: URL { url }
    }

    private(set) var items: [Item]
    var selection: URL?
    /// The ZIP archive the images come from, if any.
    let archiveURL: URL?
    /// Excluded files from a multi-file selection or ZIP, by path.
    private(set) var excludedPaths: [String]
    private var nameOrder: [Item]
    private(set) var flashedURLs: Set<URL> = []
    private var flashTask: Task<Void, Never>?
    private(set) var hashes: [URL: ContentHash] = [:]
    private var needsFreshHashes = false
    private let read: @Sendable (Item) throws -> Data

    init(
        urls: [URL], excludedURLs: [URL] = [],
        readImage: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        let items = urls.map { Item(url: $0, name: $0.lastPathComponent) }
        self.items = items
        nameOrder = items
        archiveURL = nil
        excludedPaths = excludedURLs.map(\.path)
        read = { try readImage($0.url) }
        selection = items.first?.url
    }

    /// The images of a ZIP archive in path order, decompressed from memory when needed.
    init(archive: ZipArchive, selection images: ZipImageSelection, archiveURL: URL) {
        // An archive may hold several entries with the same path, so the position in the selection keeps each one.
        let pairs = images.images.enumerated().map { index, entry in
            (
                archiveURL.appendingPathComponent(String(index), isDirectory: true).appendingPathComponent(entry.path),
                entry
            )
        }
        let entries = Dictionary(uniqueKeysWithValues: pairs)
        let items = pairs.map { url, entry in Item(url: url, name: entry.path) }
        self.items = items
        nameOrder = items
        self.archiveURL = archiveURL
        excludedPaths = images.excludedPaths
        read = { item in
            guard let entry = entries[item.url] else { throw CocoaError(.fileReadCorruptFile) }
            return try archive.contents(of: entry)
        }
        selection = items.first?.url
    }

    var urls: [URL] { items.map(\.url) }
    var isSortedByName: Bool { items == nameOrder }

    /// The excluded files by name, with the macOS resource-fork folder counted as one entry.
    var excludedSummary: [String] { Self.summarize(excludedPaths: excludedPaths) }

    static func summarize(excludedPaths: [String]) -> [String] {
        var names: [String] = []
        var counts: [String: Int] = [:]
        for path in excludedPaths {
            let name = path.hasPrefix("__MACOSX/") ? "__MACOSX" : (path as NSString).lastPathComponent
            if counts[name] == nil { names.append(name) }
            counts[name, default: 0] += 1
        }
        return names.map { name in
            let count = counts[name] ?? 1
            return count > 1 ? String(format: String(localized: "%@ (%lld)"), name, count) : name
        }
    }

    /// The set of images, independent of their order and names; nil until every image has been read.
    var setHash: ContentHash? {
        let values = items.compactMap { hashes[$0.url] }
        return values.count == items.count && !values.isEmpty ? ContentHash.imageSet(values) : nil
    }

    /// The content digests in display order, which restore the order even for renamed copies.
    var orderDigests: [String]? {
        let values = items.compactMap { hashes[$0.url]?.hex }
        return values.count == items.count && !values.isEmpty ? values : nil
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        items.move(fromOffsets: offsets, toOffset: destination)
    }

    /// Adds the images that are not in the bundle yet, by name among themselves, and returns them. A ZIP's images keep
    /// to what the archive holds; `DropPlan` never brings anything to them.
    @discardableResult
    func add(_ urls: [URL], excluded: [URL] = [], at position: Int? = nil) -> [URL] {
        var known = Set(self.urls)
        let added = Self.sorted(
            urls.map(\.standardizedFileURL).filter { known.insert($0).inserted }.map {
                Item(url: $0, name: $0.lastPathComponent)
            })
        items.insert(contentsOf: added, at: min(position ?? items.count, items.count))
        nameOrder = Self.sorted(nameOrder + added)
        excludedPaths += excluded.map(\.path).filter { !excludedPaths.contains($0) }
        if selection == nil { selection = items.first?.url }
        return added.map(\.url)
    }

    /// Takes back what an earlier `add` brought in, and leaves the rest of the list as the reader has it since.
    func undoAdding(_ urls: [URL], excluded: [URL]) {
        let added = Set(urls)
        items.removeAll { added.contains($0.url) }
        nameOrder.removeAll { added.contains($0.url) }
        excludedPaths.removeAll(where: excluded.map(\.path).contains)
        if let selected = selection, added.contains(selected) { selection = items.first?.url }
    }

    /// The list as it is, for a window that comes back after a binder took its place.
    struct ListState {
        let items: [Item]
        let excludedPaths: [String]
        let selection: URL?
    }

    var listState: ListState { ListState(items: items, excludedPaths: excludedPaths, selection: selection) }

    func restore(_ state: ListState) {
        items = state.items
        nameOrder = Self.sorted(state.items)
        excludedPaths = state.excludedPaths
        selection = state.selection
    }

    /// Lights the rows up for a moment, to show what came in or what was in the list already.
    func flash(_ urls: [URL]) {
        flashTask?.cancel()
        flashedURLs = Set(urls)
        flashTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.2)) } catch { return }
            self?.flashedURLs = []
        }
    }

    private static func sorted(_ items: [Item]) -> [Item] {
        items.sorted {
            let order = NaturalOrder.compare($0.name, $1.name)
            return order == .orderedSame ? $0.url.absoluteString < $1.url.absoluteString : order == .orderedAscending
        }
    }

    func canMoveSelection(by offset: Int) -> Bool {
        guard let selection, let index = items.firstIndex(where: { $0.url == selection }) else { return false }
        return items.indices.contains(index + offset)
    }

    func moveSelection(by offset: Int) {
        guard canMoveSelection(by: offset), let selection,
            let index = items.firstIndex(where: { $0.url == selection })
        else { return }
        items.swapAt(index, index + offset)
    }

    func sortByName() {
        guard !isSortedByName else { return }
        items = nameOrder
    }

    /// Restores a saved order; returns false when the saved digests describe other images.
    @discardableResult
    func applyOrder(_ digests: [String]) -> Bool {
        guard let ordered = ImageOrder.apply(digests, to: items, digest: { [hashes] in hashes[$0.url]?.hex ?? "" })
        else { return false }
        items = ordered
        return true
    }

    func clearCache() {
        // Keep the digests until the images have been read again, so the remembered order stays complete meanwhile.
        needsFreshHashes = true
    }

    /// Reads one image when a thumbnail needs it; nothing is cached, so a large ZIP never sits in memory.
    func data(for item: Item) async -> Data? {
        let read = read
        return await Task.detached(priority: .utility) { try? read(item) }.value
    }

    /// Hashes the images that are not known yet, one at a time without keeping their bytes, and hands the renderer
    /// images that it reads again one at a time while drawing.
    func source() async throws -> DocumentSource {
        let items = items
        let known = needsFreshHashes ? [:] : hashes
        let read = read
        let hashing = Task.detached(priority: Task.currentPriority) {
            try items.map { item -> (URL, ContentHash) in
                try Task.checkCancellation()
                return (item.url, known[item.url] ?? ContentHash.of((try? read(item)) ?? Data()))
            }
        }
        let computed = try await withTaskCancellationHandler {
            let computed = try await hashing.value
            try Task.checkCancellation()
            return computed
        } onCancel: {
            hashing.cancel()
        }
        let fresh = Dictionary(computed, uniquingKeysWith: { first, _ in first })
        hashes = fresh
        needsFreshHashes = false
        return .images(
            items.map { item in
                DocumentSource.Image(fileURL: item.url, contentHash: fresh[item.url] ?? .of(Data())) { try read(item) }
            })
    }

    func title(language: String) -> String {
        if let archiveURL {
            return String(
                format: localized("%@ — %lld images", language: language), archiveURL.lastPathComponent, items.count)
        }
        return String(
            format: localized("%lld images — %@", language: language), items.count, items.first?.name ?? "")
    }

    func exportName(layout: PrintLayout, language: String) -> String {
        let name: String
        if let archiveURL {
            name = archiveURL.deletingPathExtension().lastPathComponent
        } else {
            let first = items.first?.url.deletingPathExtension().lastPathComponent ?? String(localized: "Document")
            name =
                items.count > 1
                ? String(format: localized("%@ and %lld more", language: language), first, items.count - 1) : first
        }
        return "\(name)（\(layout.displayName(language: language))）.pdf"
    }

    private func localized(_ key: String, language: String) -> String {
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
