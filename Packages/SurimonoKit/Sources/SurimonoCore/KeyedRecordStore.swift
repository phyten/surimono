import Foundation

/// Small Codable records kept as one JSON file per key, such as the settings remembered for each document hash.
/// Reading a record marks it as recently used; saving beyond the capacity forgets the least recently used records.
public final class KeyedRecordStore<Record: Codable> {
    public enum StoreError: Error, Equatable {
        case invalidKey
    }

    public let directory: URL
    public let capacity: Int
    private let fileManager = FileManager.default

    public init(directory: URL, capacity: Int = 2000) {
        self.directory = directory
        self.capacity = max(capacity, 1)
    }

    /// Returns nil when the record is missing, is not a regular file, or cannot be decoded.
    public func record(for key: String) -> Record? {
        guard let url = fileURL(for: key) else { return nil }
        // Open the record itself, never what a symbolic link points to, and touch the very file that was read.
        // Opening a FIFO would block until a writer appears, so do not wait; non-regular files are rejected below.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            let data = try? handle.readToEnd(), let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }
        // The modification date doubles as the last use, so recently opened documents survive pruning.
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: 0, tv_nsec: Int(UTIME_NOW))]
        _ = futimens(descriptor, &times)
        return record
    }

    public func save(_ record: Record, for key: String) throws {
        guard let url = fileURL(for: key) else { throw StoreError.invalidKey }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
        prune(keeping: url)
    }

    public func removeRecord(for key: String) throws {
        guard let url = fileURL(for: key) else { throw StoreError.invalidKey }
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// The keys of all stored records, in no particular order.
    public func keys() -> [String] {
        recordFiles().map { $0.url.deletingPathExtension().lastPathComponent }
    }

    /// Keys become file names, so only short ASCII identifiers such as hexadecimal digests are accepted.
    private func fileURL(for key: String) -> URL? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        guard (1...128).contains(key.utf8.count), key.utf8.allSatisfy(allowed.contains) else { return nil }
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    private func recordFiles() -> [(url: URL, modified: Date)] {
        let urls =
            (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles))
            ?? []
        return urls.filter { $0.pathExtension == "json" }.map { url in
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            return (url, modified ?? .distantPast)
        }
    }

    private func prune(keeping kept: URL) {
        let files = recordFiles()
        guard files.count > capacity else { return }
        let oldest =
            files
            .filter { $0.url.standardizedFileURL != kept.standardizedFileURL }
            .sorted { ($0.modified, $0.url.lastPathComponent) < ($1.modified, $1.url.lastPathComponent) }
        for file in oldest.prefix(files.count - capacity) {
            try? fileManager.removeItem(at: file.url)
        }
    }
}
