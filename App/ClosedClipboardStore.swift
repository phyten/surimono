import Darwin
import Foundation
import OSLog
import SurimonoCore

/// Each immutable entry has its own file so reopening one never rewrites the others.
final class ClosedClipboardStore {
    private typealias Entry = ClosedClipboardDocuments.Entry

    private struct Record: Codable {
        let version: Int
        let sequence: UInt64
        let entry: Entry
    }

    private let directory: URL
    private let files = FileManager.default
    private let logger = Logger(subsystem: "app.surimono.Surimono", category: "ClosedClipboard")
    private var saved: [ContentHash: UUID] = [:]
    private var sequence: UInt64 = 0

    init(directory: URL) { self.directory = directory }

    private func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func prepareDirectory() throws {
        try files.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try excludeFromBackup(directory)
    }

    private func url(for id: ContentHash) -> URL { directory.appendingPathComponent(id.hex + ".json") }

    func load(now: Date) -> ClosedClipboardDocuments {
        var history = ClosedClipboardDocuments()
        guard files.fileExists(atPath: directory.path) else { return history }
        do {
            try prepareDirectory()
            var records: [Record] = []
            for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                guard url.pathExtension == "json",
                    (try? files.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular,
                    let data = try? Data(contentsOf: url),
                    let record = try? JSONDecoder().decode(Record.self, from: data), record.version == 1,
                    record.entry.closedAt.addingTimeInterval(ClosedClipboardDocuments.lifetime) > now,
                    record.entry.menuItem.id == ContentHash.of(record.entry.data),
                    url.lastPathComponent == self.url(for: record.entry.menuItem.id).lastPathComponent
                else {
                    remove(url)
                    continue
                }
                records.append(record)
            }
            for record in records.sorted(by: { ($0.entry.closedAt, $0.sequence) < ($1.entry.closedAt, $1.sequence) }) {
                history.remember(record.entry)
                saved[record.entry.menuItem.id] = record.entry.revision
                sequence = max(sequence, record.sequence)
            }
        } catch {
            logger.error("Could not load clipboard history.")
        }
        return history
    }

    func mirror(_ entries: [ClosedClipboardDocuments.Entry]) {
        let retained = Set(entries.map(\.menuItem.id))
        for key in saved.keys where !retained.contains(key) {
            if remove(url(for: key)) { saved.removeValue(forKey: key) }
        }
        do {
            for entry in entries.reversed() where saved[entry.menuItem.id] != entry.revision {
                try prepareDirectory()
                sequence &+= 1
                let data = try JSONEncoder().encode(Record(version: 1, sequence: sequence, entry: entry))
                try write(data, to: url(for: entry.menuItem.id))
                saved[entry.menuItem.id] = entry.revision
            }
        } catch {
            logger.error("Could not save clipboard history.")
        }
    }

    /// Set privacy attributes before writing even the first byte, then publish the complete file by rename.
    private func write(_ data: Data, to destination: URL) throws {
        let staging = directory.appendingPathComponent(UUID().uuidString)
        let fd = open(staging.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { try? files.removeItem(at: staging) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try excludeFromBackup(staging)
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(staging.path, destination.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    @discardableResult
    private func remove(_ url: URL) -> Bool {
        do {
            try files.removeItem(at: url)
            return true
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return true
        } catch {
            logger.error("Could not remove clipboard history.")
            return false
        }
    }

    func clear() {
        if remove(directory) { saved.removeAll() }
    }
}
