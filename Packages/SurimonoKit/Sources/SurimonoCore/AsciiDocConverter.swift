import Foundation
import JavaScriptCore
import OSLog

public enum AsciiDocConverter {
    public static func convert(_ source: String) throws -> HTMLFragment {
        // JavaScriptCore has no public execution deadline. Check bytes before entering the VM.
        guard source.utf8.count <= 5_000_000 else {
            let notice = String(localized: "AsciiDoc exceeds 5 MB. Showing the original text.")
            return HTMLFragment(body: "<p>\(HTML.escape(notice))</p>" + PlainTextConverter.convert(source).body)
        }
        let parts = try AsciiDocEngine.shared.convert(source)
        return try AsciiDocMarkup.fragment(parts)
    }
}

struct AsciiDocParts {
    let html: String
    let author: String
    let revision: String
    let language: String?
}

// The outline runs synchronously on a detached task. Core can host JavaScriptCore without any UI framework.
// Every access to the context and its JSValues is inside the lock; only Swift strings leave it.
private final class AsciiDocEngine: @unchecked Sendable {
    static let shared = AsciiDocEngine()
    private let lock = NSLock()
    private var context: JSContext?
    #if DEBUG
        private let logger = Logger(subsystem: "io.github.phyten.Surimono", category: "AsciiDoc")
    #endif

    private func script(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func load() throws -> JSContext {
        if let context { return context }
        let module = try script("asciidoctor-4.2.1")
        guard let end = module.range(of: "\nexport {", options: .backwards), let context = JSContext() else {
            throw CocoaError(.executableLoad)
        }
        // The only module URL references initialize optional Node asset paths. The host exposes no URL or IO APIs.
        context.evaluateScript(
            String(module[..<end.lowerBound]).replacingOccurrences(of: "import.meta.url", with: "''"))
        guard context.exception == nil else { throw CocoaError(.executableLoad) }
        context.evaluateScript(try script("asciidoc-bridge"))
        guard context.exception == nil else { throw CocoaError(.executableLoad) }
        self.context = context
        return context
    }

    func convert(_ source: String) throws -> AsciiDocParts {
        try lock.withLock {
            #if DEBUG
                let start = DispatchTime.now().uptimeNanoseconds
            #endif
            let context = try load()
            #if DEBUG
                let loaded = DispatchTime.now().uptimeNanoseconds
            #endif
            guard let result = context.objectForKeyedSubscript("surimonoConvert")?.call(withArguments: [source]),
                let html = result.forProperty("html"), html.isString
            else { throw CocoaError(.fileReadCorruptFile) }
            #if DEBUG
                let loadMS = Double(loaded - start) / 1e6
                let convertMS = Double(DispatchTime.now().uptimeNanoseconds - loaded) / 1e6
                logger.debug("load_ms=\(loadMS) convert_ms=\(convertMS) bytes=\(source.utf8.count)")
            #endif
            let language = result.forProperty("language")?.toString()
            return AsciiDocParts(
                html: html.toString(), author: result.forProperty("author")?.toString() ?? "",
                revision: result.forProperty("revision")?.toString() ?? "", language: language == "und" ? nil : language
            )
        }
    }
}
