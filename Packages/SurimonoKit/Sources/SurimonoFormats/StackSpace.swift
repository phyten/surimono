import Darwin
import Foundation
import SurimonoStackFrame

/// Stack for the readers whose depth follows the input.
///
/// The app converts documents on background threads with 512 KiB stacks, and the same document is also converted on
/// the main thread (structure, change marks), for the style palette and for the paper. So that all of them print the
/// same thing, the readers run on a thread of their own with a known, large stack (`onLargeStack`); the depth limits
/// that remain are then properties of the document, not of the caller. `hasRoom` stays as a last guard: a reader
/// that would still run out prints the rest as text instead of crashing.
package enum StackSpace {
    /// The stack of a conversion thread: 16 MiB, enlarged under a sanitizer. Measured, the deepest bounded nesting
    /// (LaTeX's 100 levels) needs about 2 MB in a release build and 4.2 MB in a debug build.
    package static let conversionStackSize = Int(Double(16 << 20) * sanitizerFactor)

    /// Bytes left on the current thread's stack, measured from the caller's frame on the real stack (a local's
    /// address can be on AddressSanitizer's heap-allocated fake stack). A frame outside the thread's reported stack
    /// cannot be measured; it counts as no room, so a reader prints the rest as text rather than risk overflowing.
    package static var remaining: Int {
        let thread = pthread_self()
        // The stack grows down from its address.
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let size = UInt(pthread_get_stacksize_np(thread))
        let here = UInt(surimono_frame_address())
        guard top > size, here > top - size, here <= top else { return 0 }
        return Int(here - (top - size))
    }

    /// What a reader keeps free for the work it does at one level without checking again: building a paragraph,
    /// typesetting a formula. The largest frames below a nesting level are LaTeX's paragraph and caption code, about
    /// 60 KB together in a release build and 130 KB in a debug build.
    package static let reserve: Int = {
        #if DEBUG
            let base = 160 * 1024
        #else
            let base = 128 * 1024
        #endif
        return Int(Double(base) * sanitizerFactor)
    }()

    /// Sanitizers enlarge stack frames: AddressSanitizer surrounds variables with guard bytes. Measured in a debug
    /// build, the readers' deepest stacks were 1.7 to 2.6 times as large under AddressSanitizer and 1.2 to 1.4 times
    /// under ThreadSanitizer.
    package static let sanitizerFactor: Double = {
        let process = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        if dlsym(process, "__asan_init") != nil { return 2.5 }
        return dlsym(process, "__tsan_init") != nil ? 1.5 : 1
    }()

    /// Whether the reader may go one level deeper.
    package static var hasRoom: Bool { remaining >= reserve }

    /// The reading issue of a reader that printed part of a document as text because it nested too deeply.
    package static let limitIssue = "Nesting limit reached"
    /// The reading issue of a reader that left part of a document out because it nested too deeply.
    package static let omissionIssue = "Nesting limit reached; part left out"

    private static let largeStackKey = "app.surimono.largeStack"
    private static let limitKey = "app.surimono.nestingLimitReached"
    private static let omissionKey = "app.surimono.nestingPartOmitted"

    /// The conversion thread's side of `onLargeStack`. Not generic, so that the thread's C entry point can call it.
    private class ConversionThread: @unchecked Sendable {
        // Written by the conversion thread before it ends and read by the caller after `pthread_join`, which
        // orders the two; the caller does nothing else while it waits.
        var reachedLimit = false
        var omitted = false
        // Task-local values do not automatically cross the pthread boundary.
        let deadline = PreviewConversion.deadline
        /// The caller's task, which waits for this thread and so outlives every use here.
        let task: UnsafeCurrentTask?

        init(task: UnsafeCurrentTask?) { self.task = task }

        func run() {}

        func main() {
            let dictionary = Thread.current.threadDictionary
            dictionary[StackSpace.largeStackKey] = self
            // The readers' Objective-C temporaries are released before the caller takes the result.
            PreviewConversion.$deadline.withValue(deadline) { autoreleasepool { run() } }
            reachedLimit = dictionary[StackSpace.limitKey] != nil
            omitted = dictionary[StackSpace.omissionKey] != nil
            dictionary[StackSpace.largeStackKey] = nil
        }

        /// Starts a thread with `stackSize` that runs `main()`; false when the system refuses one.
        func start(stackSize: Int) -> pthread_t? {
            var attributes = pthread_attr_t()
            guard pthread_attr_init(&attributes) == 0 else { return nil }
            defer { pthread_attr_destroy(&attributes) }
            guard pthread_attr_setstacksize(&attributes, stackSize) == 0 else { return nil }
            // The caller waits for this thread; it works at the caller's quality of service.
            pthread_attr_set_qos_class_np(&attributes, qos_class_self(), 0)
            var thread: pthread_t?
            let context = Unmanaged.passRetained(self).toOpaque()
            let status = pthread_create(
                &thread, &attributes,
                { context in
                    Unmanaged<ConversionThread>.fromOpaque(context).takeRetainedValue().main()
                    return nil
                }, context)
            guard status == 0, let thread else {
                Unmanaged<ConversionThread>.fromOpaque(context).release()
                return nil
            }
            return thread
        }
    }

    private final class Job<Value: Sendable, Failure: Error>: ConversionThread, @unchecked Sendable {
        // `body` is a non-escaping closure made escapable only while the caller waits in `pthread_join`; it is
        // released on the conversion thread before that thread ends. `result` is written there and read after.
        var body: (@Sendable () throws(Failure) -> Value)?
        var result: Result<Value, Failure>?

        init(_ body: @escaping @Sendable () throws(Failure) -> Value, task: UnsafeCurrentTask?) {
            self.body = body
            super.init(task: task)
        }

        override func run() {
            if let body { result = Result { () throws(Failure) -> Value in try body() } }
            body = nil
        }
    }

    /// Runs `body` on a fresh thread with `conversionStackSize` and waits for it; on such a thread already, runs it in
    /// place. The caller's thread is blocked meanwhile, so whatever `body` captures (a converter's file callbacks)
    /// runs on the conversion thread: it is `@Sendable`, and must not need the caller's thread, actor or task-local
    /// values. `StackSpace.isCancelled` there reports the caller's task.
    ///
    /// When the system refuses a thread, a reader whose recursion `hasRoom` guards runs on the caller's stack, where
    /// the guard keeps a deep document from overflowing it. A reader without such a guard passes `withoutThread`,
    /// which is used instead unless the caller's stack has as much room left as half a conversion thread's.
    package static func onLargeStack<Value: Sendable, Failure: Error>(
        _ body: @Sendable () throws(Failure) -> Value, withoutThread: (() throws(Failure) -> Value)? = nil
    ) throws(Failure) -> Value {
        if Thread.current.threadDictionary[largeStackKey] != nil { return try body() }
        let result: Result<Value, Failure>? = withoutActuallyEscaping(body) { escapable in
            withUnsafeCurrentTask { task in
                let job = Job(escapable, task: task)
                guard !refusesThreads, let thread = job.start(stackSize: conversionStackSize) else { return nil }
                pthread_join(thread, nil)
                if job.reachedLimit { noteLimitReached() }
                if job.omitted { noteOmitted() }
                return job.result
            }
        }
        if let result { return try result.get() }
        if let withoutThread, remaining < conversionStackSize / 2 { return try withoutThread() }
        return try body()
    }

    private static let refusesThreadsKey = "app.surimono.refusesConversionThreads"

    /// Whether this thread behaves as if the system refused every new thread (set by tests).
    package static var refusesThreads: Bool { Thread.current.threadDictionary[refusesThreadsKey] != nil }

    /// Runs `body` with every conversion thread refused on this thread, as when the system cannot make one.
    package static func refusingThreads<Value>(_ body: () throws -> Value) rethrows -> Value {
        let dictionary = Thread.current.threadDictionary
        let outer = dictionary[refusesThreadsKey]
        dictionary[refusesThreadsKey] = true
        defer { dictionary[refusesThreadsKey] = outer }
        return try body()
    }

    private final class DetachedBody: @unchecked Sendable {
        // Handed to exactly one new thread, which runs it once.
        let run: @Sendable () -> Void
        init(_ run: @escaping @Sendable () -> Void) { self.run = run }
    }

    /// Starts a thread of its own for `body` with `stackSize`, at the caller's quality of service, and tells whether
    /// the system made one: `Thread.start()` reports no failure, and a thread that never ran could not give back
    /// what its caller reserved for it.
    package static func detachThread(stackSize: Int, _ body: @escaping @Sendable () -> Void) -> Bool {
        guard !refusesThreads else { return false }
        var attributes = pthread_attr_t()
        guard pthread_attr_init(&attributes) == 0 else { return false }
        defer { pthread_attr_destroy(&attributes) }
        guard pthread_attr_setstacksize(&attributes, stackSize) == 0,
            pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED) == 0
        else { return false }
        pthread_attr_set_qos_class_np(&attributes, qos_class_self(), 0)
        let context = Unmanaged.passRetained(DetachedBody(body)).toOpaque()
        var thread: pthread_t?
        let status = pthread_create(
            &thread, &attributes,
            { context in
                Unmanaged<DetachedBody>.fromOpaque(context).takeRetainedValue().run()
                return nil
            }, context)
        guard status == 0 else {
            Unmanaged<DetachedBody>.fromOpaque(context).release()
            return false
        }
        return true
    }

    /// Whether the task that a conversion runs for is cancelled, on its conversion thread as on its own.
    package static var isCancelled: Bool {
        if let thread = Thread.current.threadDictionary[largeStackKey] as? ConversionThread {
            return thread.task?.isCancelled ?? false
        }
        return Task.isCancelled
    }

    /// Notes that a reader on this thread printed part of its input as text because it nested too deeply.
    package static func noteLimitReached() {
        Thread.current.threadDictionary[limitKey] = true
    }

    /// Notes that a reader on this thread left part of its input out because it nested too deeply.
    package static func noteOmitted() {
        Thread.current.threadDictionary[omissionKey] = true
    }

    /// Runs `body` and tells whether a reader on this thread noted an omission meanwhile. Outer collections also see
    /// it.
    package static func collectingOmission<Value, Failure: Error>(_ body: () throws(Failure) -> Value) throws(Failure)
        -> (value: Value, omitted: Bool)
    {
        let dictionary = Thread.current.threadDictionary
        let outer = dictionary[omissionKey] != nil
        dictionary[omissionKey] = nil
        defer {
            if outer { dictionary[omissionKey] = true }
        }
        let value = try body()
        let omitted = dictionary[omissionKey] != nil
        if omitted { dictionary[omissionKey] = true }
        return (value, omitted)
    }

    /// Runs `body` and tells whether a reader on this thread noted the limit meanwhile. Outer collections also see it.
    package static func collectingLimit<Value, Failure: Error>(_ body: () throws(Failure) -> Value) throws(Failure)
        -> (value: Value, reachedLimit: Bool)
    {
        let dictionary = Thread.current.threadDictionary
        let outer = dictionary[limitKey] != nil
        dictionary[limitKey] = nil
        defer {
            if outer { dictionary[limitKey] = true }
        }
        let value = try body()
        let reached = dictionary[limitKey] != nil
        if reached { dictionary[limitKey] = true }
        return (value, reached)
    }
}

extension HTMLFragment {
    /// The fragment with the omission reading issue added once, when `omitted`.
    func notingOmission(_ omitted: Bool) -> HTMLFragment {
        guard omitted, !readingIssues.contains(StackSpace.omissionIssue) else { return self }
        var fragment = self
        fragment.readingIssues.append(StackSpace.omissionIssue)
        return fragment
    }

    /// The fragment with the nesting-limit reading issue added once, when `reached`.
    func notingLimit(_ reached: Bool) -> HTMLFragment {
        guard reached, !readingIssues.contains(StackSpace.limitIssue) else { return self }
        var fragment = self
        fragment.readingIssues.append(StackSpace.limitIssue)
        return fragment
    }
}
