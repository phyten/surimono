import AppIntents
import AppKit
import SurimonoCore
import UniformTypeIdentifiers

/// What the Shortcuts actions work with. The app sets it at launch; tests put their own in its place.
enum ShortcutEnvironment {
    static var preferences: AppPreferences?
    static var library: UserLibrary?
    static var router: OpenRouter = .shared
    static var fileAccess: ShortcutFileAccess = .shared
}

/// A failure Shortcuts shows to whoever ran the action.
nonisolated struct ShortcutFailure: Error, CustomLocalizedStringResourceConvertible, LocalizedError {
    let message: String

    var localizedStringResource: LocalizedStringResource { "\(message)" }
    var errorDescription: String? { message }
}

/// The layouts of the print tray. Shortcuts needs the cases at build time, so they are spelled out here, and a test
/// keeps them the same as `PrintLayout.presets`.
nonisolated enum ShortcutLayout: String, AppEnum {
    case a4Single, a4Duplex, a3BookletA4, a4BookletA5, a3TwoUp, a4Handout3, a4TwoUp, a4FourUp
    case b5Single, b5Duplex, b4BookletB5, b5BookletB6, b4TwoUp, b5Handout3, b5TwoUp, b5FourUp
    case letterSingle, letterDuplex, tabloidBookletLetter, letterBookletHalfLetter, tabloidTwoUp, letterHandout3
    case letterTwoUp, letterFourUp

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Layout", table: "Shortcuts"))

    static let caseDisplayRepresentations: [ShortcutLayout: DisplayRepresentation] = [
        .a4Single: DisplayRepresentation(title: LocalizedStringResource("A4 Single-sided", table: "Shortcuts")),
        .a4Duplex: DisplayRepresentation(title: LocalizedStringResource("A4 Duplex", table: "Shortcuts")),
        .a3BookletA4: DisplayRepresentation(title: LocalizedStringResource("A3 Booklet → A4", table: "Shortcuts")),
        .a4BookletA5: DisplayRepresentation(title: LocalizedStringResource("A4 Booklet → A5", table: "Shortcuts")),
        .a3TwoUp: DisplayRepresentation(title: LocalizedStringResource("A3 2-up", table: "Shortcuts")),
        .a4Handout3: DisplayRepresentation(title: LocalizedStringResource("A4 3-up + Notes", table: "Shortcuts")),
        .a4TwoUp: DisplayRepresentation(title: LocalizedStringResource("A4 2-up", table: "Shortcuts")),
        .a4FourUp: DisplayRepresentation(
            title: LocalizedStringResource("A4 4 Pages on One Sheet", table: "Shortcuts")),
        .b5Single: DisplayRepresentation(title: LocalizedStringResource("B5 (JIS) Single-sided", table: "Shortcuts")),
        .b5Duplex: DisplayRepresentation(title: LocalizedStringResource("B5 (JIS) Duplex", table: "Shortcuts")),
        .b4BookletB5: DisplayRepresentation(
            title: LocalizedStringResource("B4 (JIS) Booklet → B5 (JIS)", table: "Shortcuts")),
        .b5BookletB6: DisplayRepresentation(
            title: LocalizedStringResource("B5 (JIS) Booklet → B6 (JIS)", table: "Shortcuts")),
        .b4TwoUp: DisplayRepresentation(title: LocalizedStringResource("B4 (JIS) 2-up", table: "Shortcuts")),
        .b5Handout3: DisplayRepresentation(
            title: LocalizedStringResource("B5 (JIS) 3-up + Notes", table: "Shortcuts")),
        .b5TwoUp: DisplayRepresentation(title: LocalizedStringResource("B5 (JIS) 2-up", table: "Shortcuts")),
        .b5FourUp: DisplayRepresentation(
            title: LocalizedStringResource("B5 (JIS) 4 Pages on One Sheet", table: "Shortcuts")),
        .letterSingle: DisplayRepresentation(
            title: LocalizedStringResource("Letter Single-sided", table: "Shortcuts")),
        .letterDuplex: DisplayRepresentation(title: LocalizedStringResource("Letter Duplex", table: "Shortcuts")),
        .tabloidBookletLetter: DisplayRepresentation(
            title: LocalizedStringResource("Tabloid Booklet → Letter", table: "Shortcuts")),
        .letterBookletHalfLetter: DisplayRepresentation(
            title: LocalizedStringResource("Letter Booklet → Half Letter", table: "Shortcuts")),
        .tabloidTwoUp: DisplayRepresentation(title: LocalizedStringResource("Tabloid 2-up", table: "Shortcuts")),
        .letterHandout3: DisplayRepresentation(
            title: LocalizedStringResource("Letter 3-up + Notes", table: "Shortcuts")),
        .letterTwoUp: DisplayRepresentation(title: LocalizedStringResource("Letter 2-up", table: "Shortcuts")),
        .letterFourUp: DisplayRepresentation(
            title: LocalizedStringResource("Letter 4 Pages on One Sheet", table: "Shortcuts")),
    ]
}

/// The styles to pick from, by the names the style menus show. A name typed by hand works as well.
nonisolated struct ShortcutStyleOptions: DynamicOptionsProvider {
    @MainActor
    func results() async throws -> [String] {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        return (ShortcutEnvironment.library ?? UserLibrary()).themes.map { $0.displayName(language: language) }
    }
}

struct ExportPDFIntent: AppIntent {
    static let title = LocalizedStringResource("Export PDF with Surimono", table: "Shortcuts")
    static let description = IntentDescription(
        LocalizedStringResource(
            "Lays a file out on paper with one of Surimono's print layouts and styles, and returns the PDF. The file itself is not changed.",
            table: "Shortcuts"))
    /// The pages are laid out in a window that is never shown, so the app has no reason to come forward. Nothing is
    /// written beside the file or into the reader's folders: the layout's intermediate files live in the app's
    /// temporary directory and are removed, and the PDF goes back in memory.
    static let openAppWhenRun = false

    @Parameter(
        title: LocalizedStringResource("File", table: "Shortcuts"),
        supportedContentTypes: [.plainText, .html, .pdf, .image, .commaSeparatedText, .tabSeparatedText])
    var file: IntentFile

    @Parameter(
        title: LocalizedStringResource("Layout", table: "Shortcuts"),
        description: LocalizedStringResource(
            "Leave empty to use the default in Surimono's settings.", table: "Shortcuts"))
    var layout: ShortcutLayout?

    @Parameter(
        title: LocalizedStringResource("Style", table: "Shortcuts"),
        description: LocalizedStringResource(
            "Leave empty to use the default in Surimono's settings.", table: "Shortcuts"),
        optionsProvider: ShortcutStyleOptions())
    var style: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$file) as a PDF", table: "Shortcuts") {
            \.$layout
            \.$style
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let name = (file.filename as NSString).deletingPathExtension
        guard let format = ShortcutFiles.format(of: file) else {
            throw ShortcutFailure(
                message: String(
                    localized: "“\(file.filename)” is not a file Surimono can export as a PDF.", table: "Shortcuts"))
        }
        let export = HeadlessExport(
            preferences: ShortcutEnvironment.preferences ?? AppPreferences(),
            library: ShortcutEnvironment.library ?? UserLibrary())
        // The app may have been started in the background just for this; it must not greet anyone with a window.
        let router = ShortcutEnvironment.router
        router.beginHeadlessWork()
        defer { router.endHeadlessWork() }
        do {
            // The layout reads the file's neighbours too, so the access lasts until the pages are done.
            let output = try await ShortcutEnvironment.fileAccess.reading(file.fileURL) {
                try await export.export(
                    file.data, fileURL: file.fileURL, format: format, name: name.isEmpty ? file.filename : name,
                    layoutID: layout?.rawValue, style: style.flatMap { $0.isEmpty ? nil : $0 })
            }
            return .result(value: IntentFile(data: output.data, filename: output.fileName, type: .pdf))
        } catch let failure as HeadlessExport.Failure {
            throw ShortcutFailure(message: failure.message)
        }
    }
}

struct OpenInPrintModeIntent: AppIntent {
    static let title = LocalizedStringResource("Open in Surimono's Print Mode", table: "Shortcuts")
    static let description = IntentDescription(
        LocalizedStringResource(
            "Opens files in Surimono's print mode, with the sheets laid out and ready to print. Nothing is sent to the printer until you press Print.",
            table: "Shortcuts"))
    static let openAppWhenRun = true

    @Parameter(
        title: LocalizedStringResource("Files", table: "Shortcuts"),
        supportedContentTypes: [
            .plainText, .html, .pdf, .image, .commaSeparatedText, .tabSeparatedText, .zip,
        ])
    var files: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$files) in the print mode", table: "Shortcuts")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let inputs = files.map { file in
            ShortcutFiles.Input(
                url: file.fileURL, isTemporary: file.removedOnCompletion, name: file.filename,
                format: ShortcutFiles.format(of: file))
        }
        let access = ShortcutEnvironment.fileAccess
        let opened: Bool
        switch ShortcutFiles.plan(inputs) {
        case .files(let urls):
            // The windows go on reading the files after this returns, so each takes its files' access with it.
            opened = ShortcutEnvironment.router.open(urls, printing: true, access: access.leases(for: urls))
        case .memory(let index, let format):
            // The file is gone when the shortcut ends, so its bytes are taken now.
            let file = files[index]
            let data = await access.reading(file.fileURL) { file.data }
            opened = ShortcutEnvironment.router.open(
                .document(data: data, format: format), printing: true, title: file.filename)
        case .saveFirst:
            throw ShortcutFailure(
                message: String(
                    localized:
                        "These files exist only while the shortcut runs. Save them with a Save File action first, then open the saved files.",
                    table: "Shortcuts"))
        case .none:
            opened = false
        }
        guard opened else {
            throw ShortcutFailure(
                message: String(localized: "There are no files Surimono can open.", table: "Shortcuts"))
        }
        return .result()
    }
}

enum ShortcutFiles {
    nonisolated static func format(of file: IntentFile) -> DocumentFormat? {
        DocumentFormat(fileExtension: (file.filename as NSString).pathExtension)
            ?? file.type.flatMap(DocumentFormat.init(contentType:))
    }

    nonisolated struct Input {
        let url: URL?
        /// Shortcuts removes the file when the shortcut ends, as it does with what an earlier action made.
        let isTemporary: Bool
        let name: String
        let format: DocumentFormat?

        var stays: Bool { url != nil && !isTemporary }
    }

    nonisolated enum Plan: Equatable {
        case files([URL])
        /// The input at this index, read into memory.
        case memory(Int, DocumentFormat)
        case saveFirst
        case none
    }

    /// Files that stay open as any other files do. A window must not point at a file that is about to go, so one
    /// such file opens from memory instead. Several of them, or an archive, need files to read from: a bundle and a
    /// binder read their files as they show them, and an archive's window reads the archive.
    nonisolated static func plan(_ inputs: [Input]) -> Plan {
        if inputs.isEmpty { return .none }
        if inputs.allSatisfy(\.stays) { return .files(inputs.compactMap(\.url)) }
        guard inputs.count == 1 else { return .saveFirst }
        guard let format = inputs[0].format else { return .none }
        return format == .zipArchive ? .saveFirst : .memory(0, format)
    }
}

nonisolated struct SurimonoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ExportPDFIntent(),
            phrases: ["Export a PDF with \(.applicationName)"],
            shortTitle: LocalizedStringResource("Export PDF", table: "Shortcuts"),
            systemImageName: "arrow.down.doc")
        AppShortcut(
            intent: OpenInPrintModeIntent(),
            phrases: ["Open in the print mode of \(.applicationName)"],
            shortTitle: LocalizedStringResource("Open in Print Mode", table: "Shortcuts"),
            systemImageName: "printer")
    }
}
