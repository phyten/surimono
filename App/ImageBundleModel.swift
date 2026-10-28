import Foundation
import Observation
import SurimonoCore
import SurimonoRendering
import SwiftUI

@Observable
final class ImageBundleModel {
    private(set) var urls: [URL]
    var selection: URL?
    private var loaded: [URL: Data] = [:]
    private let readImage: @Sendable (URL) throws -> Data

    init(urls: [URL], readImage: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.urls = urls
        selection = urls.first
        self.readImage = readImage
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        urls.move(fromOffsets: offsets, toOffset: destination)
    }

    func canMoveSelection(by offset: Int) -> Bool {
        guard let selection, let index = urls.firstIndex(of: selection) else { return false }
        return urls.indices.contains(index + offset)
    }

    func moveSelection(by offset: Int) {
        guard canMoveSelection(by: offset), let selection, let index = urls.firstIndex(of: selection) else { return }
        urls.swapAt(index, index + offset)
    }

    func clearCache() { loaded = [:] }

    func source() async throws -> DocumentSource {
        let urls = urls
        let cached = loaded
        let read = readImage
        let loading = Task.detached(priority: Task.currentPriority) {
            try urls.map { url in
                try Task.checkCancellation()
                return DocumentSource.Image(data: cached[url] ?? ((try? read(url)) ?? Data()), fileURL: url)
            }
        }
        let images = try await withTaskCancellationHandler {
            let images = try await loading.value
            try Task.checkCancellation()
            return images
        } onCancel: {
            loading.cancel()
        }
        loaded = Dictionary(uniqueKeysWithValues: images.map { ($0.fileURL, $0.data) })
        return .images(images)
    }

    func title(language: String) -> String {
        String(
            format: localized("%lld images — %@", language: language), urls.count, urls.first?.lastPathComponent ?? "")
    }

    func exportName(layout: PrintLayout, language: String) -> String {
        let first = urls.first?.deletingPathExtension().lastPathComponent ?? String(localized: "Document")
        let name =
            urls.count > 1
            ? String(format: localized("%@ and %lld more", language: language), first, urls.count - 1) : first
        return "\(name)（\(layout.displayName(language: language))）.pdf"
    }

    private func localized(_ key: String, language: String) -> String {
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
