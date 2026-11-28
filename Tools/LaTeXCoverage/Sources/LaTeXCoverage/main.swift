import Foundation
import LaTeXCoverageCore
import SurimonoFormats

// latex-coverage run <corpus> <out> [--manifest <file>] [--baseline <run>] [--jobs <n>] [--timeout <s>] [--html]
// latex-coverage compare <before run> <after run>
// latex-coverage worker <corpus> <manuscript json> <record out> [<html out>]
//
// The corpus is read, never written. Each paper is read in its own worker process, so that a paper which crashes or
// hangs the reader is counted as such without losing the others.

let usage = """
    usage: latex-coverage run <corpus> <out> [--manifest <file>] [--baseline <run>] [--jobs <n>] [--timeout <s>] [--html]
           latex-coverage compare <before run> <after run>
    The corpus holds the manuscripts (one folder each, or a manifest.json); out receives documents.jsonl,
    summary.json, summary.md and the manifest used. A run is an out folder or its documents.jsonl.

    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail(usage) }
arguments.removeFirst()

@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

@MainActor func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}

func absolute(_ path: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL
}

switch command {
case "worker":
    guard arguments.count >= 3 else { fail(usage) }
    let manuscript: Manuscript
    do {
        manuscript = try JSONDecoder().decode(Manuscript.self, from: Data(arguments[1].utf8))
    } catch {
        fail("worker: \(error)")
    }
    let (record, body) = Worker.read(manuscript, corpus: absolute(arguments[0]))
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: absolute(arguments[2]), options: .atomic)
        if arguments.count > 3 { try Data(body.utf8).write(to: absolute(arguments[3]), options: .atomic) }
    } catch {
        fail("worker: \(error)")
    }

case "run":
    let manifest = option("--manifest").map(absolute)
    let baseline = option("--baseline").map(absolute)
    let jobs = option("--jobs").flatMap(Int.init) ?? max(1, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
    let timeout = option("--timeout").flatMap(Double.init) ?? 60
    let keepsHTML = flag("--html")
    guard arguments.count == 2 else { fail(usage) }
    let corpus = absolute(arguments[0])
    let out = absolute(arguments[1])
    do {
        let papers = try Manuscripts.list(corpus: corpus, manifest: manifest)
        guard !papers.isEmpty else { fail("No manuscripts in \(corpus.path)") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Keep the papers fixed for the next run: a guessed main file is not guessed again.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(papers).write(to: out.appending(path: "manifest.json"), options: .atomic)
        let records = Runner(corpus: corpus, out: out, jobs: jobs, timeout: timeout, keepsHTML: keepsHTML).run(papers)
        try CoverageFiles.write(records, to: out)
        print(try String(contentsOf: out.appending(path: "summary.md"), encoding: .utf8))
        if let baseline {
            let comparison = CoverageComparison(before: try CoverageFiles.read(baseline), after: records)
            try Data(comparison.markdown.utf8).write(to: out.appending(path: "comparison.md"), options: .atomic)
            print(comparison.markdown)
        }
        print("Wrote \(out.path)")
    } catch {
        fail("run: \(error)")
    }

case "compare":
    guard arguments.count == 2 else { fail(usage) }
    do {
        let comparison = CoverageComparison(
            before: try CoverageFiles.read(absolute(arguments[0])),
            after: try CoverageFiles.read(absolute(arguments[1])))
        print(comparison.markdown)
    } catch {
        fail("compare: \(error)")
    }

default:
    fail(usage)
}
