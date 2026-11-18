import Foundation
import JavaScriptCore
import OSLog

struct ScriptDocument {
    let html: String
    let author: String
    let revision: String
    let language: String?
}

// The outline runs synchronously on a detached task. Core can host JavaScriptCore without any UI framework.
// Every access to the context and its JSValues is inside the lock; only Swift strings leave it.
final class ScriptConverterHost: @unchecked Sendable {
    private let library: String
    private let bridge: String
    private let commonJS: Bool

    init(_ library: String, bridge: String, category: String, commonJS: Bool = true) {
        self.library = library
        self.bridge = bridge
        self.commonJS = commonJS
        #if DEBUG
            logger = Logger(subsystem: "io.github.phyten.Surimono", category: category)
        #endif
    }
    private let lock = NSLock()
    private var context: JSContext?
    #if DEBUG
        private let logger: Logger
    #endif

    private func script(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func load() throws -> JSContext {
        if let context { return context }
        var module = try script(library)
        guard let context = JSContext() else { throw CocoaError(.executableLoad) }
        if commonJS {
            context.evaluateScript("var module = {exports: {}}; var exports = module.exports;")
        } else {
            // The Asciidoctor ES module uses its URL only for optional Node assets.
            guard let end = module.range(of: "\nexport {", options: .backwards) else {
                throw CocoaError(.executableLoad)
            }
            module = String(module[..<end.lowerBound]).replacingOccurrences(of: "import.meta.url", with: "''")
        }
        context.evaluateScript(module)
        guard context.exception == nil else { throw CocoaError(.executableLoad) }
        context.evaluateScript(try script(bridge))
        guard context.exception == nil else { throw CocoaError(.executableLoad) }
        self.context = context
        return context
    }

    private func parts(_ source: String) throws -> ScriptDocument {
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
            return ScriptDocument(
                html: html.toString(), author: result.forProperty("author")?.toString() ?? "",
                revision: result.forProperty("revision")?.toString() ?? "",
                language: result.forProperty("language")?.toString())
        }
    }

    func fragment(
        _ source: String, notice: @autoclosure () -> String,
        rewrite: (ScriptDocument) throws -> HTMLFragment
    ) throws -> HTMLFragment {
        // JavaScriptCore has no public execution deadline. Check bytes before entering the VM.
        guard source.utf8.count <= 5_000_000 else {
            return HTMLFragment(body: "<p>\(HTML.escape(notice()))</p>" + PlainTextConverter.convert(source).body)
        }
        return try rewrite(parts(source))
    }
}
