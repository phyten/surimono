import AppKit
import SurimonoCore
import UniformTypeIdentifiers

struct SettingSetFiles {
    static func read(_ urls: [URL]) throws -> [PrintSettingSet] {
        try urls.flatMap { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try PrintSettingSetArchive.decode(Data(contentsOf: url))
        }
    }

    static func write(_ sets: [PrintSettingSet], to url: URL, protecting sources: [URL]) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard DocumentViewModel.canExport(to: url, sourceURLs: sources) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try PrintSettingSetArchive.encode(sets).write(to: url, options: .atomic)
    }

    static func chooseImport(completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { if $0 == .OK { completion(panel.urls) } }
    }

    static func chooseExport(named name: String, completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue =
            name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".json"
        panel.begin { if $0 == .OK, let url = panel.url { completion(url) } }
    }
}
