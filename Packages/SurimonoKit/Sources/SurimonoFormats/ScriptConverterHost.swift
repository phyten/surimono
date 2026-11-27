import Foundation
import JavaScriptCore
import OSLog

struct ScriptDocument {
    let html: String
    let author: String
    let revision: String
    let language: String?
    var combinedContents = false
    var leadContents: String?
    var readingHeader: AsciiDocReadingHeader?
    var contentsTitle: String?
    var regionalNumbers: String?
    var hasContentsMacro = false
}

// The outline runs synchronously on a detached task. Formats can host JavaScriptCore without any UI framework.
// Every conversion loads a context of its own on a thread of its own, and the context ends with that thread: a
// JSVirtualMachine runs its deferred work (garbage collection) on the run loop of the thread that made it, so a
// context kept after its thread ended would have none. Loading takes 2 to 30 ms (Textile, Djot, Word, Asciidoctor,
// measured in a debug build). JavaScriptCore has no public way to stop a script, so a conversion that runs past its
// deadline is abandoned on its thread, which ends when the script does. Stopping a script that never ends, or that
// keeps allocating, needs a helper process the app could end; that is not built.
final class ScriptConverterHost: @unchecked Sendable {
    private let library: String
    private let bridge: String
    private let prelude: String?
    private let commonJS: Bool

    init(
        _ library: String, bridge: String, category: String, commonJS: Bool = true, prelude: String? = nil,
        testing: Testing? = nil
    ) {
        self.testing = testing
        self.prelude = prelude
        self.library = library
        self.bridge = bridge
        self.commonJS = commonJS
        #if DEBUG
            logger = Logger(subsystem: "app.surimono.Surimono", category: category)
        #endif
    }
    // Guards `running`, `abandoned`, `scriptsStarted` and every job's state.
    private let lock = NSLock()
    /// Conversion threads alive, abandoned ones included. A conversion reserves a slot before its thread starts and
    /// the thread frees it when its script ends. An abandoned script keeps a core busy and may keep allocating (an
    /// AsciiDoc table cell spanning 9,999,999 columns took over 3 GB before the bridge capped spans), so at most three
    /// run per format; a document that finds no slot before its deadline is shown as its text with the same notice as
    /// a slow one, at once when every slot is held by an abandoned script. A script that never ends keeps its slot
    /// until the app quits: only a helper process, which could be ended, would free it.
    private var running = 0
    /// Of `running`, the conversions whose caller gave up.
    private var abandoned = 0
    private static let maximumRunning = 3
    /// What a test sets once, when it makes its own host; the converters' hosts have none, and then none of it runs.
    struct Testing: Sendable {
        /// Points on a conversion's thread where a test can hold it or learn that it got there.
        enum Point: Sendable { case loaded, finished }

        /// Lets a test observe calls to the bundled parser before the bridge wraps it.
        var beforeBridge: String?
        /// A script run after the bridge in every new context.
        var script: String?
        /// Called on the conversion's thread at each `Point`.
        var hook: (@Sendable (Point) -> Void)?
        /// Asked while the caller waits for the conversion: true gives it up, as its deadline passing would.
        var givesUp: (@Sendable () -> Bool)?

        init(
            beforeBridge: String? = nil, script: String? = nil, hook: (@Sendable (Point) -> Void)? = nil,
            givesUp: (@Sendable () -> Bool)? = nil
        ) {
            self.beforeBridge = beforeBridge
            self.script = script
            self.hook = hook
            self.givesUp = givesUp
        }
    }

    private let testing: Testing?
    /// Under `lock`, and counted only for a host made with `testing`: document scripts started, and the times a
    /// conversion waited for a slot.
    private var scriptsStarted = 0
    private var slotWaits = 0
    var startedScripts: Int { lock.withLock { scriptsStarted } }
    var waitsForSlot: Int { lock.withLock { slotWaits } }
    #if DEBUG
        private let logger: Logger
    #endif

    enum ScriptError: Error, Equatable {
        /// The script ran past the time its input allows.
        case timedOut
        /// The system made no thread for the conversion; the document cannot be read now.
        case unavailable
    }

    /// The time a conversion may take: 4 seconds per 100 KB of input, at least 3 and at most 60 seconds. The readers
    /// are linear on ordinary documents (a 100 KB document converts in well under a second); a slower one is shown
    /// as its text rather than leaving the document waiting.
    static func deadline(forBytes count: Int) -> Duration {
        .milliseconds(min(60_000, max(3_000, count / 25)))
    }

    static func scriptURL(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }

    private func script(_ name: String) throws -> String {
        try String(contentsOf: Self.scriptURL(name), encoding: .utf8)
    }

    private func load() throws -> JSContext {
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
        if let prelude {
            context.evaluateScript(try script(prelude))
            guard context.exception == nil else { throw CocoaError(.executableLoad) }
        }
        context.evaluateScript(module)
        guard context.exception == nil else { throw CocoaError(.executableLoad) }
        if let script = testing?.beforeBridge { context.evaluateScript(script) }
        context.evaluateScript(try script(bridge))
        guard context.exception == nil else { throw CocoaError(.executableLoad) }
        if let script = testing?.script { context.evaluateScript(script) }
        return context
    }

    private enum JobState { case running, completed, abandoned }

    /// What a conversion running on its own thread shares with the caller waiting for it.
    private final class Job<Value>: @unchecked Sendable {
        // `state`, `result` and `completedInTime` are read and written under the host's lock. The state leaves
        // `.running` once: to `.completed` by the thread or to `.abandoned` by the caller, whichever gets the lock
        // first.
        var state = JobState.running
        var result: Result<Value, any Error>?
        var completedInTime = false
        let done = DispatchSemaphore(value: 0)
    }

    private enum Reservation { case reserved, busy, allAbandoned }

    /// Runs `work` with a fresh context on a thread of its own and waits for it until the deadline, or until the
    /// caller's task is cancelled (`StackSpace.isCancelled`, which also answers on a conversion thread). The deadline
    /// and cancellation are checked when a slot is reserved, when the thread starts, after the context has loaded
    /// (right before the document's script starts), while the script runs and when its outcome is taken. A
    /// completion after the deadline or for a cancelled caller is not used.
    private func withContext<Value: Sendable>(
        deadline: Duration,
        _ work: @escaping @Sendable (JSContext, _ isCancelled: () -> Bool, _ begin: () throws -> Void) throws -> Value
    ) throws -> Value {
        // Finder must finish every worker before it replies, including any future optional conversion paths.
        guard !PreviewConversion.isActive else { throw ScriptError.unavailable }
        let end = ContinuousClock.now + deadline
        // The waits below last 50 ms at most and never past the deadline.
        func step() -> Double {
            let left = max(.zero, min(end - ContinuousClock.now, .milliseconds(50)))
            return Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18
        }
        while true {
            if StackSpace.isCancelled { throw CancellationError() }
            if ContinuousClock.now >= end { throw ScriptError.timedOut }
            let reservation = lock.withLock { () -> Reservation in
                guard running < Self.maximumRunning else {
                    return abandoned >= Self.maximumRunning ? .allAbandoned : .busy
                }
                running += 1
                return .reserved
            }
            switch reservation {
            case .reserved: break
            // No slot will free up before scripts that already ran past their deadlines end, if they ever do.
            case .allAbandoned: throw ScriptError.timedOut
            case .busy:
                if testing != nil { lock.withLock { slotWaits += 1 } }
                Thread.sleep(forTimeInterval: step())
                continue
            }
            break
        }
        let job = Job<Value>()
        // JavaScriptCore derives its own recursion limit from the thread's stack, so the scripts get room to work.
        let started = StackSpace.detachThread(stackSize: 8 << 20) { [self] in
            let stopped = { self.lock.withLock { job.state != .running } || ContinuousClock.now > end }
            // Objective-C objects the script's values make are released with the job, before the caller hears of it.
            let outcome = autoreleasepool {
                Result { () throws -> Value in
                    if stopped() { throw CancellationError() }
                    let vm = try load()
                    testing?.hook?(.loaded)
                    // The document's script starts only through `begin`, which decides under the same lock as an
                    // abandoning caller: a job given up on, or past its deadline, never starts it.
                    let begin = { () throws -> Void in
                        try self.lock.withLock { () throws -> Void in
                            guard job.state == .running, ContinuousClock.now <= end else { throw CancellationError() }
                            if self.testing != nil { self.scriptsStarted += 1 }
                        }
                    }
                    return try work(vm, stopped, begin)
                }
            }
            lock.withLock {
                running -= 1
                guard job.state == .running else {
                    abandoned -= 1
                    return
                }
                job.state = .completed
                job.result = outcome
                job.completedInTime = ContinuousClock.now <= end
            }
            job.done.signal()
            testing?.hook?(.finished)
        }
        guard started else {
            // No thread will give the slot back.
            lock.withLock { running -= 1 }
            throw ScriptError.unavailable
        }
        while job.done.wait(timeout: .now() + step()) == .timedOut {
            let late = ContinuousClock.now >= end || testing?.givesUp?() == true
            let stop: (any Error)? = StackSpace.isCancelled ? CancellationError() : late ? ScriptError.timedOut : nil
            guard let stop else { continue }
            let gaveUp = lock.withLock { () -> Bool in
                guard job.state == .running else { return false }
                job.state = .abandoned
                abandoned += 1
                return true
            }
            if gaveUp { throw stop }
            // The thread completed first; its outcome is decided below.
            break
        }
        // The outcome is taken here, by the caller.
        if StackSpace.isCancelled { throw CancellationError() }
        let (result, inTime) = lock.withLock { (job.result, job.completedInTime) }
        guard inTime else { throw ScriptError.timedOut }
        guard let result else { throw CocoaError(.executableLoad) }
        return try result.get()
    }

    /// Native Promise continuations drain when a call returns to Swift. Each round also notices a cancelled or
    /// abandoned conversion.
    func wordHTML(_ bytes: Data, maximumRounds: Int) throws -> String {
        do {
            return try withContext(deadline: Self.deadline(forBytes: bytes.count)) {
                vm, isCancelled, begin in
                try self.wordHTML(bytes, maximumRounds: maximumRounds, in: vm, isCancelled: isCancelled, begin: begin)
            }
        } catch ScriptError.timedOut {
            throw DocxError.conversionFailed
        }
    }

    private func wordHTML(
        _ bytes: Data, maximumRounds: Int, in vm: JSContext, isCancelled: () -> Bool, begin: () throws -> Void
    ) throws -> String {
        #if DEBUG
            let start = DispatchTime.now().uptimeNanoseconds
        #endif
        guard
            let array = JSObjectMakeTypedArray(
                vm.jsGlobalContextRef, kJSTypedArrayTypeUint8Array, bytes.count, nil),
            let value = JSValue(jsValueRef: array, in: vm),
            let buffer = JSObjectGetTypedArrayBytesPtr(vm.jsGlobalContextRef, array, nil)
        else { throw DocxError.conversionFailed }
        bytes.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: bytes.count)
        // After the buffer is ready, the last step before the document's script.
        try begin()
        vm.objectForKeyedSubscript("startWord")?.call(withArguments: [value])
        let pump = vm.objectForKeyedSubscript("pump")
        for _ in 0..<max(0, maximumRounds) {
            if isCancelled() { throw CancellationError() }
            guard vm.exception == nil else { throw DocxError.conversionFailed }
            if let result = vm.objectForKeyedSubscript("wordResult"), result.isObject {
                guard let html = result.forProperty("html"), html.isString else { throw DocxError.conversionFailed }
                #if DEBUG
                    let convertMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                    let warnings = result.forProperty("warnings")?.toInt32() ?? 0
                    logger.debug("convert_ms=\(convertMS) warnings=\(warnings)")
                #endif
                vm.setObject(NSNull(), forKeyedSubscript: "wordResult" as NSString)
                return html.toString()
            }
            pump?.call(withArguments: [])
        }
        throw DocxError.conversionFailed
    }

    private func parts(_ source: String, contentsDepth: Int?, asciiDocReading: FormatReadingSettings?) throws
        -> ScriptDocument
    {
        try withContext(deadline: Self.deadline(forBytes: source.utf8.count)) {
            context, isCancelled, begin in
            #if DEBUG
                let start = DispatchTime.now().uptimeNanoseconds
            #endif
            let header = asciiDocReading.map {
                AsciiDocReadingHeader.install(in: context, source: source, reading: $0, contentsDepth: contentsDepth)
            }
            try begin()
            guard
                let result = context.objectForKeyedSubscript("surimonoConvert")?.call(
                    withArguments: contentsDepth.map { [source, $0] } ?? [source]),
                let html = result.forProperty("html"), html.isString
            else { throw CocoaError(.fileReadCorruptFile) }
            #if DEBUG
                let convertMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
                self.logger.debug("convert_ms=\(convertMS) bytes=\(source.utf8.count)")
            #endif
            // A caller that gave up meanwhile gets nothing.
            if isCancelled() { throw CancellationError() }
            // A property the bridge left out is `undefined` (or `null`), whose `toString()` is that word.
            func text(_ name: String) -> String? {
                guard let value = result.forProperty(name), value.isString else { return nil }
                return value.toString()
            }
            return ScriptDocument(
                html: html.toString(), author: text("author") ?? "", revision: text("revision") ?? "",
                language: text("language"), combinedContents: text("combinedContents") == "true",
                leadContents: text("leadContents"), readingHeader: header?(), contentsTitle: text("contentsTitle"),
                regionalNumbers: text("regionalNumbers"), hasContentsMacro: text("hasContentsMacro") == "true")
        }
    }

    func fragment(
        _ source: String, contentsDepth: Int? = nil, asciiDocReading: FormatReadingSettings? = nil,
        notice: @autoclosure () -> String,
        rewrite: (ScriptDocument) throws -> HTMLFragment
    ) throws -> HTMLFragment {
        // Check bytes before entering the VM; a document that fits but converts too slowly is shown as text too.
        guard source.utf8.count <= DocumentSizeLimits.markupReaderBytes else {
            return HTMLFragment(body: "<p>\(HTML.escape(notice()))</p>" + PlainTextConverter.convert(source).body)
        }
        let document: ScriptDocument
        do {
            document = try parts(source, contentsDepth: contentsDepth, asciiDocReading: asciiDocReading)
        } catch ScriptError.timedOut {
            let message = String(localized: "This document took too long to read. Showing the original text.")
            return HTMLFragment(body: "<p>\(HTML.escape(message))</p>" + PlainTextConverter.convert(source).body)
        }
        return try rewrite(document)
    }
}
