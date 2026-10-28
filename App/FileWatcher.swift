import Foundation

@MainActor
final class FileWatcher {
    enum Event: Equatable { case changed, removed }
    private var task: Task<Void, Never>?

    // Poll the path, not an open descriptor: editors commonly replace the inode on save.
    // Metadata avoids repeatedly reading large PDFs and also detects same-size writes.
    private nonisolated struct Stamp: Equatable, Sendable {
        let size: UInt64
        let inode: UInt64
        let modified: Date?
        let created: Date?

        nonisolated static func read(_ url: URL) -> Self? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return Self(
                size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                modified: attributes[.modificationDate] as? Date,
                created: attributes[.creationDate] as? Date)
        }
    }

    init(url: URL, onChange: @escaping @MainActor (Event) -> Void) {
        let initial = Stamp.read(url)
        task = Task.detached(priority: .utility) {
            var delivered = initial
            var pending = initial
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                let current = Stamp.read(url)
                if current != pending {
                    pending = current
                    continue
                }
                if current != delivered {
                    delivered = current
                    guard !Task.isCancelled else { return }
                    await onChange(current == nil ? .removed : .changed)
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
