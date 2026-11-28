import Foundation
import LaTeXCoverageCore
import SurimonoFormats

/// Reads one paper as the app reads a document, with companion files confined to the paper's folder.
enum Worker {
    static func read(_ manuscript: Manuscript, corpus: URL) -> (DocumentRecord, String) {
        let folder = corpus.appending(path: manuscript.folder).standardizedFileURL
        let main = folder.appending(path: manuscript.main).standardizedFileURL
        var record = DocumentRecord(id: manuscript.id, main: manuscript.main, outcome: .ok)
        record.group = manuscript.group
        record.year = manuscript.year
        guard let root = try? ConfinedFile.canonicalPath(folder), let data = try? ConfinedFile.read(main, within: root)
        else {
            record.outcome = .crashed
            record.failure = "main file could not be read"
            return (record, "")
        }
        let text = TextDecoding.decode(data).text
        record.documentClass = Self.documentClass(text)
        let reads = Reads(root: root)
        let start = Date()
        let (fragment, report) = LaTeXConverter.convertWithReport(
            text, documentURL: main,
            imageExists: { url in
                guard let path = try? ConfinedFile.canonicalPath(url), path.hasPrefix(root + "/") else { return false }
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            },
            imageSizeInPoints: { _ in nil },
            readFile: { url in
                let data = try? ConfinedFile.read(url, within: root, maximumSize: 8_000_004)
                reads.note(url, ok: data != nil)
                return data
            },
            modificationDate: { url in
                guard let path = try? ConfinedFile.canonicalPath(url), path.hasPrefix(root + "/") else { return nil }
                return try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            },
            fileIdentity: { $0.resolvingSymlinksInPath().standardizedFileURL })
        record.seconds = Date().timeIntervalSince(start)
        record.bodyBytes = fragment.body.utf8.count
        if let info = fragment.latexClass {
            switch info.recognition {
            case .recognised(let name, _, _)?:
                record.recognition = "recognised"
                record.recognisedName = name.text(japanese: false)
            case .substituted?: record.recognition = "substituted"
            case nil: record.recognition = "none"
            }
            record.page.beamerUnreadableFrames = info.unreadableBeamerFrames
            record.page.beamerTheme = info.unsupportedBeamerTheme != nil
        }
        let counts = PageCounts(html: fragment.body, mainFolder: main.deletingLastPathComponent(), paperFolder: folder)
        record.page.frames = counts.frames
        record.page.pictureFrames = counts.pictureFrames
        record.page.pictureReasons = counts.pictureReasons
        record.page.picturesDrawn = counts.picturesDrawn
        record.page.formulasAsSource = counts.formulasAsSource
        record.page.imagesMissing = counts.imagesMissing
        record.page.imagesEPS = counts.imagesEPS
        record.page.citationsMissing = counts.citationsMissing
        record.diagnostics = report.diagnostics.map {
            DocumentRecord.Diagnostic(
                kind: $0.kind.rawValue, name: $0.name, detail: $0.detail, cause: $0.formula?.code,
                command: $0.formula?.command)
        }
        let budget = report.budget
        func stop(_ stop: LaTeXBudgetUse.Stop?) -> DocumentRecord.Stop? {
            stop.map {
                DocumentRecord.Stop(
                    limit: $0.limit.rawValue, site: $0.site, command: $0.command, macro: $0.macro, file: $0.file,
                    detail: $0.detail, calls: $0.calls, characters: $0.characters, work: $0.work)
            }
        }
        record.budget = DocumentRecord.Budget(
            stop: stop(budget.stop), mathStop: stop(budget.mathStop), calls: budget.calls,
            characters: budget.characters, work: budget.work,
            heaviest: budget.heaviest.map {
                DocumentRecord.Charge(command: $0.command, calls: $0.calls, characters: $0.characters, work: $0.work)
            })
        record.reads = reads.list
        return (record, fragment.body)
    }

    /// The class as the preamble names it, for tables only.
    static func documentClass(_ text: String) -> String? {
        guard
            let match = text.range(
                of: #"(?m)^[^%\n]*\\documentclass\s*(\[[^\]]*\])?\s*\{([^}]*)\}"#, options: .regularExpression)
        else { return nil }
        let line = text[match]
        guard let open = line.lastIndex(of: "{"), let close = line.lastIndex(of: "}") else { return nil }
        return line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
    }
}

/// The files the reader asked for, from the converter's own thread while the caller waits for it.
final class Reads: @unchecked Sendable {
    // Every access goes through `lock`.
    private let lock = NSLock()
    private var results: [String: Bool] = [:]
    private let root: String

    init(root: String) { self.root = root }

    func note(_ url: URL, ok: Bool) {
        let path = url.standardizedFileURL.path
        let key = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : url.lastPathComponent
        lock.withLock { results[key] = (results[key] ?? false) || ok }
    }

    var list: [DocumentRecord.Read] {
        lock.withLock { results.map { DocumentRecord.Read(path: $0.key, ok: $0.value) }.sorted { $0.path < $1.path } }
    }
}
