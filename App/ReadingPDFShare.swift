import AppKit
import UniformTypeIdentifiers

/// Owns one presentation and its promised PDF. Services may request the same representation more than once.
final class ReadingPDFShare: NSObject, NSSharingServicePickerDelegate {
    private let name: String
    private let protectedURLs: [URL]
    private var prepare: (@MainActor () async throws -> Data)?
    private var picker: NSSharingServicePicker?
    private var task: Task<Void, Never>?
    private var file: URL?
    private var requests: [UUID: (Result<URL, Error>) -> Void] = [:]

    init(name: String, protectedURLs: [URL], prepare: @escaping @MainActor () async throws -> Data) {
        self.name = name
        self.protectedURLs = protectedURLs
        self.prepare = prepare
    }

    isolated deinit { cancel() }

    func show(in view: NSView) {
        let provider = NSItemProvider()
        provider.suggestedName = name
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all
        ) {
            [weak self] completion in
            let progress = Progress(totalUnitCount: 1)
            Task { @MainActor [weak self] in
                guard let self else {
                    completion(nil, false, CancellationError())
                    return
                }
                load(progress) { result in
                    switch result {
                    case .success(let file): completion(file, false, nil)
                    case .failure(let error): completion(nil, false, error)
                    }
                }
            }
            return progress
        }
        let picker = NSSharingServicePicker(items: [provider])
        self.picker = picker
        picker.delegate = self
        picker.show(
            relativeTo: CGRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1),
            of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?
    ) {
        guard picker === sharingServicePicker else { return }
        picker = nil
        // A chosen service can still ask for its file after dismissing the picker.
        if service == nil { cancel() }
    }

    func load(_ progress: Progress, completion: @escaping (Result<URL, Error>) -> Void) {
        guard !progress.isCancelled else {
            completion(.failure(CancellationError()))
            return
        }
        if let file {
            progress.completedUnitCount = 1
            completion(.success(file))
            return
        }
        guard let prepare else {
            completion(.failure(CancellationError()))
            return
        }
        let id = UUID()
        requests[id] = { result in
            progress.cancellationHandler = nil
            if case .success = result { progress.completedUnitCount = 1 }
            completion(result)
        }
        progress.cancellationHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.cancelLoad(id) }
        }
        if progress.isCancelled {
            cancelLoad(id)
            return
        }
        guard task == nil else { return }
        task = Task { [weak self] in
            do {
                let bytes = try await prepare()
                try Task.checkCancellation()
                guard let self else { return }
                let file = try writeFile(bytes)
                self.file = file
                self.prepare = nil
                finish(.success(file))
            } catch {
                // Cancellation already completed its callers. A later request may have started a fresh task.
                if !Task.isCancelled { self?.finish(.failure(error)) }
            }
        }
    }

    private func cancelLoad(_ id: UUID) {
        guard let completion = requests.removeValue(forKey: id) else { return }
        if requests.isEmpty {
            task?.cancel()
            task = nil
        }
        completion(.failure(CancellationError()))
    }

    func cancel() {
        prepare = nil
        let file = self.file
        self.file = nil
        let active = picker
        picker = nil
        active?.delegate = nil
        active?.close()
        task?.cancel()
        finish(.failure(CancellationError()))
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }

    private func finish(_ result: Result<URL, Error>) {
        task = nil
        let pending = requests
        requests.removeAll()
        for completion in pending.values { completion(result) }
    }

    private func writeFile(_ bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let file = directory.appendingPathComponent(name)
            guard DocumentViewModel.canExport(to: file, sourceURLs: protectedURLs) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try bytes.write(to: file, options: .withoutOverwriting)
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
