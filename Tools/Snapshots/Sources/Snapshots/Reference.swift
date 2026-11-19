import Foundation

struct CorpusEntry: Decodable {
    let id, dir, engine: String
    let features: [String]
}
private enum TeXFailure: Error { case missing(String) }
private func executable(_ name: String) throws -> URL {
    let paths =
        ["/Library/TeX/texbin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
    for path in paths {
        let url = URL(fileURLWithPath: path).appendingPathComponent(name)
        if fm.isExecutableFile(atPath: url.path) { return url }
    }
    throw TeXFailure.missing(name)
}
private func typeset(_ row: CorpusEntry, source: URL, scratch: URL) throws -> Data {
    guard ["pdflatex", "xelatex", "lualatex"].contains(row.engine), validID(row.id),
        row.dir.hasPrefix(row.id + "-"), !row.dir.contains("/")
    else { throw SnapshotError("Invalid corpus entry") }
    let work = scratch.appendingPathComponent(row.dir)
    try fm.copyItem(at: source.appendingPathComponent(row.dir), to: work)
    defer { try? fm.removeItem(at: work) }
    func invoke(_ name: String, _ args: [String]) throws -> String {
        let task = Process()
        let output = Pipe()
        task.executableURL = try executable(name)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/Library/TeX/texbin:" + (env["PATH"] ?? "")
        env["SOURCE_DATE_EPOCH"] = "1778716800"
        env["FORCE_SOURCE_DATE"] = "1"
        env["TZ"] = "UTC"
        env["TEXMFCACHE"] = scratch.path
        env["TEXMFVAR"] = scratch.path
        env["PAR_GLOBAL_TMPDIR"] = scratch.path
        task.environment = env
        task.currentDirectoryURL = work
        task.arguments = args
        task.standardOutput = output
        task.standardError = output
        try task.run()
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            if let missing = log.components(separatedBy: "\n").first(where: {
                $0.contains("not found") && ($0.contains(".cls") || $0.contains(".sty"))
            }) {
                throw TeXFailure.missing(missing)
            }
            throw SnapshotError(String(log.suffix(1800)))
        }
        return log
    }
    // pdfTeX otherwise embeds absolute installation paths when a class imports a PDF as a form.
    let input = row.engine == "pdflatex" ? #"\pdfsuppressptexinfo=15\relax\input{main.tex}"# : "main.tex"
    let args = ["-no-shell-escape", "-interaction=nonstopmode", "-halt-on-error", "-jobname=main", input]
    _ = try invoke(row.engine, args)
    if row.features.contains("biber") {
        _ = try invoke("biber", ["main"])
    } else if row.features.contains(where: { $0.hasPrefix("bibtex:") }) {
        _ = try invoke("bibtex", ["main"])
    }
    for _ in 0..<4 {
        let log = try invoke(row.engine, args)
        guard !log.contains("Missing character:") else { throw SnapshotError("Missing glyph in \(row.id)") }
        if ![
            "Rerun to get", "Label(s) may have changed", "undefined references", "undefined citations",
            "Please rerun LaTeX",
        ].contains(where: log.contains) {
            let pdf = work.appendingPathComponent("main.pdf")
            _ = try PDFInput(pdf)
            return try Data(contentsOf: pdf)
        }
    }
    throw SnapshotError("References did not converge")
}
func reference(base: URL, ids: Set<String>) throws {
    let corpus = base.appendingPathComponent("corpus/latex")
    let scratch = fm.temporaryDirectory.appendingPathComponent("surimono-tex-" + UUID().uuidString)
    try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: scratch) }
    let environment = base.appendingPathComponent("reference/environment.json")
    var versions = try read([String: String].self, environment)
    var failures = 0
    for row in try read([CorpusEntry].self, corpus.appendingPathComponent("manifest.json")) where ids.contains(row.id) {
        do {
            let pdf = try typeset(row, source: corpus, scratch: scratch)
            let version = try shell(executable(row.engine).path, ["--version"]).components(separatedBy: "\n")[0]
            try write(pdf, base.appendingPathComponent("reference/latex/" + row.id + ".pdf"))
            if let defaultVersion = versions["texLive"], version.contains(defaultVersion) {
                versions.removeValue(forKey: row.id)
            } else {
                versions[row.id] = version
            }
            try write(try encoded(versions), environment)
            print("\(row.id)  \(version)")
        } catch TeXFailure.missing(let reason) { print("\(row.id)  skipped: \(reason)") } catch {
            failures += 1
            print("\(row.id)  error: \(error)")
        }
    }
    if failures > 0 { throw SnapshotError("\(failures) TeX compilation failures") }
}
