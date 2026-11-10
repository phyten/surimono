import Foundation
import SurimonoCore
import SurimonoRendering

/// Lays a document out on sheets without a window, as the print tray's Export as PDF does, for callers outside the
/// app. It starts from the app's defaults: what a window remembers for a document belongs to that window's reader.
/// Nothing is written beside the document or into the reader's folders: the layout's intermediate files live in the
/// app's temporary directory and are removed, and the PDF is handed back in memory.
struct HeadlessExport {
    struct Failure: Error, Equatable {
        let message: String
    }

    struct Output {
        let data: Data
        let layout: PrintLayout
        /// The name Export as PDF suggests for the same document and layout.
        let fileName: String
    }

    let preferences: AppPreferences
    let library: UserLibrary
    private let renderer: DocumentRenderer

    init(preferences: AppPreferences, library: UserLibrary, renderer: DocumentRenderer = DocumentRenderer()) {
        self.preferences = preferences
        self.library = library
        self.renderer = renderer
    }

    private var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The names a style answers to: its identifier, its English name, and its name in the app's language.
    func theme(named name: String) -> PrintTheme? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.themes.first { theme in
            [theme.id, theme.name, theme.displayName(language: language)].contains {
                $0.compare(wanted, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
            }
        }
    }

    func settings(format: DocumentFormat, name: String, layoutID: String?, style: String?) throws -> RenderSettings {
        let layoutID = layoutID ?? preferences.layoutID
        let layout = PrintLayout.presets.first { $0.id == layoutID } ?? .a4Single
        let standard = library.themes.first { $0.id == "standard" }
        let theme: PrintTheme?
        if let style, format.usesPrintTheme {
            guard let named = self.theme(named: style) else {
                throw Failure(
                    message: String(localized: "There is no style named “\(style)”.", table: "Shortcuts"))
            }
            theme = named
        } else {
            let id = format.usesPrintTheme ? preferences.themeID : "standard"
            theme = library.themes.first { $0.id == id } ?? standard
        }
        let presetID = format.usesHTMLPreset ? preferences.presetID : "none"
        let preset = library.presets.first { $0.id == presetID } ?? library.presets.first { $0.id == "none" }
        guard let theme, let preset else {
            throw Failure(message: String(localized: "Print styles could not be loaded. Reload them in Settings."))
        }
        var settings = RenderSettings(
            layout: layout, theme: theme, preset: preset, options: preferences.printOptions,
            allowsJavaScriptInHTML: preferences.allowsJavaScript,
            textScale: format.usesPrintTheme ? preferences.defaultTextScale : 1,
            paperOrientation: preferences.defaultPaperOrientation)
        settings.documentName = name
        settings.pageLanguage = language
        if format.usesPrintTheme {
            settings.finish = preferences.printFinish
            let palette = library.codePalette(preferences.defaultCodePaletteID)
            settings.code = CodeStyle(
                palette: palette, block: CodeBlockOptions(), cutFormat: String(localized: "+%d characters"))
        }
        return settings
    }

    /// `fileURL` only tells the layout where the document's images are; the document is read from `data`.
    func export(
        _ data: Data, fileURL: URL?, format: DocumentFormat, name: String, layoutID: String? = nil, style: String? = nil
    ) async throws -> Output {
        // An archive is a bundle of images, which only a window puts in order.
        guard format != .zipArchive else {
            throw Failure(
                message: String(localized: "“\(name)” is not a file Surimono can export as a PDF.", table: "Shortcuts"))
        }
        let settings = try settings(format: format, name: name, layoutID: layoutID, style: style)
        let result: RenderResult
        do {
            result = try await renderer.render(
                DocumentSource(data: data, fileURL: fileURL, format: format), settings: settings)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Failure(message: DocumentViewModel.message(for: error))
        }
        guard let pdf = result.sheetDocument.dataRepresentation() else {
            throw Failure(message: String(localized: "The PDF could not be exported."))
        }
        return Output(
            data: pdf, layout: result.layout,
            fileName: DocumentViewModel.exportName(
                fileURL: nil, layout: result.layout, language: language, title: name))
    }
}
