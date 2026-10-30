import AppKit
import Observation
import SurimonoCore

@Observable
final class UserLibrary {
    private(set) var themes: [PrintTheme] = []
    private(set) var themeCategories: [PrintThemeCategory] = []
    private(set) var presets: [HTMLCleanupPreset] = []
    private(set) var presetErrors: [HTMLCleanupPresetLoadError] = []
    private(set) var error: String?
    private(set) var revision = 0
    let root: URL

    /// A development build keeps its own folder, so it never reads or rewrites the installed app's styles, presets and
    /// document settings. The folder names locate users' data, so they must not change.
    static var defaultRoot: URL {
        #if DEBUG
            let folder = "Surimono Dev"
        #else
            let folder = "Surimono"
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folder, isDirectory: true)
    }

    init(root: URL? = nil) {
        self.root = root ?? Self.defaultRoot
        reload()
    }

    func reload() {
        error = nil
        do {
            themes = try PrintThemeLibrary.load(userDirectory: root.appendingPathComponent("Styles"))
        } catch {
            self.error = error.localizedDescription
            // A broken user stylesheet must not hide the bundled themes.
            themes = (try? PrintThemeLibrary.load()) ?? []
        }
        do {
            themeCategories = try PrintThemeLibrary.categories()
        } catch {
            self.error = error.localizedDescription
            // Without categories the menus still offer the recent, favorite, suggested and user styles.
            themeCategories = []
        }
        do {
            let loaded = try HTMLCleanupPresetLibrary.load(userDirectory: root.appendingPathComponent("Presets"))
            presets = loaded.presets
            presetErrors = loaded.errors
        } catch {
            self.error = error.localizedDescription
            // A failed user directory must not prevent rendering unrelated document formats.
            presets = (try? HTMLCleanupPresetLibrary.load())?.presets ?? []
            presetErrors = []
        }
        revision += 1
    }

    func openFolder(_ name: String) {
        do {
            let url = root.appendingPathComponent(name, isDirectory: true)
            let isNew = !FileManager.default.fileExists(atPath: url.path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            if name == "Presets", isNew {
                let example = HTMLCleanupPreset(
                    id: "user:example", name: "Example", localizedNames: ["ja": "見本"],
                    removeSelectors: ["nav", "aside"], extraCSS: "body { color: black; }")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                var data = try encoder.encode(example)
                data.append(0x0A)
                try data.write(to: url.appendingPathComponent("example.json.sample"), options: .atomic)
            }
            if !NSWorkspace.shared.open(url) { throw CocoaError(.fileReadUnknown) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
