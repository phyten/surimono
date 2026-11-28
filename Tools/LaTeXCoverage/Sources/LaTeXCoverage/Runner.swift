import Foundation
import LaTeXCoverageCore

/// Runs one worker process per paper, a few at a time, and stops one that runs past the time limit.
struct Runner {
    let corpus: URL
    let out: URL
    let jobs: Int
    let timeout: Double
    let keepsHTML: Bool

    func run(_ papers: [Manuscript]) -> [DocumentRecord] {
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        let scratch = out.appending(path: "records")
        let pages = out.appending(path: "html")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        if keepsHTML { try? FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true) }
        let results = Results(count: papers.count)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = jobs
        for (index, paper) in papers.enumerated() {
            queue.addOperation {
                let name = paper.id.replacingOccurrences(of: "/", with: "_")
                let recordURL = scratch.appending(path: name + ".json")
                let htmlURL = pages.appending(path: name + ".html")
                results.set(
                    index, run(paper, executable: executable, record: recordURL, html: keepsHTML ? htmlURL : nil))
                let done = results.finished()
                if done.isMultiple(of: 25) || done == papers.count {
                    FileHandle.standardError.write(Data("\(done)/\(papers.count)\n".utf8))
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        try? FileManager.default.removeItem(at: scratch)
        return results.records
    }

    private func run(_ paper: Manuscript, executable: URL, record: URL, html: URL?) -> DocumentRecord {
        let process = Process()
        process.executableURL = executable
        guard let manuscript = try? String(decoding: JSONEncoder().encode(paper), as: UTF8.self) else {
            return DocumentRecord(id: paper.id, main: paper.main, outcome: .crashed)
        }
        process.arguments = ["worker", corpus.path, manuscript, record.path] + (html.map { [$0.path] } ?? [])
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        var failed = DocumentRecord(id: paper.id, main: paper.main, outcome: .crashed)
        failed.group = paper.group
        failed.year = paper.year
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            failed.failure = "\(error)"
            return failed
        }
        // The pipe is drained while the worker runs, so that a long error output cannot block it.
        let errorText = SharedText()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errorText.value = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            drained.signal()
        }
        let start = Date()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            finished.wait()
            drained.wait()
            failed.outcome = .timeout
            failed.seconds = Date().timeIntervalSince(start)
            return failed
        }
        drained.wait()
        guard process.terminationStatus == 0, let data = try? Data(contentsOf: record),
            let decoded = try? JSONDecoder().decode(DocumentRecord.self, from: data)
        else {
            failed.failure = "status \(process.terminationStatus): " + String(errorText.value.suffix(400))
            failed.seconds = Date().timeIntervalSince(start)
            return failed
        }
        return decoded
    }
}

/// Filled in by the workers' operations while `run` waits for all of them.
final class Results: @unchecked Sendable {
    // Every access goes through `lock`.
    private let lock = NSLock()
    private var stored: [DocumentRecord?]
    private var done = 0

    init(count: Int) { stored = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ record: DocumentRecord) {
        lock.withLock {
            stored[index] = record
            done += 1
        }
    }

    func finished() -> Int { lock.withLock { done } }

    var records: [DocumentRecord] { lock.withLock { stored.compactMap { $0 } } }
}

final class SharedText: @unchecked Sendable {
    // Every access goes through `lock`.
    private let lock = NSLock()
    private var stored = ""

    var value: String {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
