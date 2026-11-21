import Foundation
import SurimonoFormats

package enum LaTeXCorpus {
    package static func dump(extension suffix: String, contents: (HTMLFragment) throws -> String) throws {
        guard let path = ProcessInfo.processInfo.environment["SURIMONO_LATEX_DUMP"], !path.isEmpty else { return }
        let manager = FileManager.default
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try manager.createDirectory(at: output, withIntermediateDirectories: true)
        try forEachDocument { name, fragment in
            let file = output.appendingPathComponent(name).appendingPathExtension(suffix)
            try Data(contents(fragment).utf8).write(to: file, options: .atomic)
        }
    }

    package static func forEachDocument(_ visit: (String, HTMLFragment) throws -> Void) throws {
        let manager = FileManager.default
        let repository = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let corpus = repository.appendingPathComponent("Snapshots/corpus/latex")
        let folders = try manager.contentsOfDirectory(at: corpus, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { manager.fileExists(atPath: $0.appendingPathComponent("main.tex").path) }
        guard !folders.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        for folder in folders.sorted(by: { $0.path < $1.path }) {
            let source = folder.appendingPathComponent("main.tex")
            // Fixed file URLs keep embedded image links independent of the checkout location.
            let directory = URL(fileURLWithPath: "/corpus/" + folder.lastPathComponent, isDirectory: true)
            func companion(_ url: URL) -> URL? {
                let prefix = directory.path + "/"
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(prefix) else { return nil }
                return folder.appendingPathComponent(String(path.dropFirst(prefix.count)))
            }
            let fragment = LaTeXConverter.convert(
                try String(contentsOf: source, encoding: .utf8), fontIndex: InstalledFontIndex(faces: [:]),
                documentURL: directory.appendingPathComponent("main.tex"),
                imageExists: { url in companion(url).map { manager.fileExists(atPath: $0.path) } ?? false },
                readFile: { url in companion(url).flatMap { try? Data(contentsOf: $0) } })
            try visit(folder.lastPathComponent, fragment)
        }
    }
}
