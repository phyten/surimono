import Foundation

@MainActor
final class FileWatcher {
    enum Event: Equatable, Sendable { case check, changed, removed }
    private var task: Task<Void, Never>?
    private var stopped = false
    private(set) var isReady = false

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

    init(
        url: URL, beforeCheck: @escaping @Sendable () -> Void = {},
        onChange: @escaping @MainActor (Event) -> Void
    ) {
        task = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            beforeCheck()
            guard !Task.isCancelled else { return }
            let initial = Stamp.read(url)
            // The model may hold bytes older than the first poll. Reconcile even when metadata stays equal.
            await self?.deliver(initial == nil ? .removed : .check, to: onChange)
            var delivered = initial
            var pending = initial
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                beforeCheck()
                guard !Task.isCancelled else { return }
                let current = Stamp.read(url)
                if current != pending {
                    pending = current
                    continue
                }
                if current != delivered {
                    delivered = current
                    await self?.deliver(current == nil ? .removed : .changed, to: onChange)
                }
            }
        }
    }

    private func deliver(_ event: Event, to onChange: @MainActor (Event) -> Void) {
        // Check again on the main actor: stop() may run while this delivery is queued.
        guard !stopped, !Task.isCancelled else { return }
        isReady = true
        onChange(event)
    }

    func stop() {
        stopped = true
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
