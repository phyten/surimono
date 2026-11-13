import Foundation
import PDFKit
import SurimonoRendering

final class ThemeSampleCache {
    let directory: URL

    init(directory: URL) { self.directory = directory }

    static var application: ThemeSampleCache? {
        // Hosted tests must opt into a temporary cache rather than touching the user's samples.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
            let bundleID = Bundle.main.bundleIdentifier,
            let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        return ThemeSampleCache(directory: root.appendingPathComponent(bundleID).appendingPathComponent("ThemeSamples"))
    }

    func page(for key: String) -> PDFPage? {
        let url = directory.appendingPathComponent(key + ".pdf")
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data),
            document.pageCount == 1, !document.isLocked, let page = StandalonePage.first(of: document),
            page.bounds(for: .mediaBox).width > 0, page.bounds(for: .mediaBox).height > 0
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return page
    }

    func store(_ page: PDFPage, for key: String) {
        guard let copy = StandalonePage.copy(of: page) else { return }
        let document = PDFDocument()
        document.insert(copy, at: 0)
        guard let data = document.dataRepresentation() else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(key + ".pdf"), options: .atomic)
        } catch {
            // A cache is optional; the already drawn page remains usable when storage is unavailable.
        }
    }

    struct Entry {
        let url: URL
        let size: Int
        let used: Date
    }

    static func removing(from entries: [Entry], countLimit: Int = 600, byteLimit: Int = 50 * 1024 * 1024) -> [URL] {
        var count = entries.count
        var bytes = entries.reduce(0) { $0 + $1.size }
        var removed: [URL] = []
        for entry in entries.sorted(by: { ($0.used, $0.url.path) < ($1.used, $1.url.path) }) {
            guard count > countLimit || bytes > byteLimit else { break }
            removed.append(entry.url)
            count -= 1
            bytes -= entry.size
        }
        return removed
    }

    func prune() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
        else { return }
        let entries = urls.compactMap { url -> Entry? in
            guard url.pathExtension == "pdf", let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else { return nil }
            return Entry(url: url, size: values.fileSize ?? 0, used: values.contentModificationDate ?? .distantPast)
        }
        for url in Self.removing(from: entries) { try? FileManager.default.removeItem(at: url) }
    }
}
