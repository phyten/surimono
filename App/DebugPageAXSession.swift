#if DEBUG
    import AppKit
    import SurimonoCore

    /// A private document gives the external reader unambiguous text without writing to a reader's open file.
    enum DebugPageAXSession {
        static private(set) var current: Session?

        struct Session {
            let directory: URL
            let fixture: URL
            let token = UUID().uuidString
            let operation: String
            let count: Int
        }

        private struct Stage: Encodable {
            let pid: Int32
            let token: String
            let operation: String
            let count: Int
            let sequence: Int
            let phase: String
            let generation: Int
            let axElements: ShownDocumentsProbe.ElementMetrics
        }

        static func start() throws {
            guard let path = DebugSnapshot.argument("SurimonoAXProbeDirectory") else { return }
            guard path.hasPrefix("/"), let operation = DebugSnapshot.argument("SurimonoAXOperation"),
                ["reload", "layout", "tray"].contains(operation),
                let count = Int(DebugSnapshot.argument("SurimonoRerenderCount") ?? "50"), count > 0
            else { throw CocoaError(.fileWriteInvalidFileName) }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            // A run can neither consume stale acknowledgements nor overwrite a previous run.
            guard mkdir(path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
            let session = Session(
                directory: directory, fixture: scratch.appending(path: "Paper.md"), operation: operation, count: count)
            do {
                try writeFixture(session, generation: 0)
                current = session
                guard OpenRouter.shared.open([session.fixture]) else { throw CocoaError(.fileReadUnknown) }
            } catch {
                current = nil
                try? FileManager.default.removeItem(at: scratch)
                throw error
            }
        }

        @discardableResult private static func writeFixture(_ session: Session, generation: Int) throws -> Data {
            let marker = "世代 \(generation)。"
            let source = "# \(marker)\n\n" + Array(repeating: "\(marker) 紙面の本文です。\n\n", count: 90).joined()
            let data = Data(source.utf8)
            try data.write(to: session.fixture, options: .atomic)
            return data
        }

        static func run(_ model: DocumentViewModel, session: Session) async throws {
            defer {
                current = nil
                try? FileManager.default.removeItem(at: session.fixture.deletingLastPathComponent())
            }
            var sequence = 0
            func wait(_ stage: String, for ready: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(90)
                while !ready() {
                    if (try? String(contentsOf: session.directory.appending(path: "abort"), encoding: .utf8))
                        == session.token
                    {
                        throw CancellationError()
                    }
                    guard model.window != nil, model.error == nil, ContinuousClock.now < deadline else {
                        throw SnapshotDeadline(stage: stage)
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }

            func publish(_ phase: String, generation: Int) async throws {
                let stage = Stage(
                    pid: getpid(), token: session.token, operation: session.operation, count: session.count,
                    sequence: sequence, phase: phase, generation: generation,
                    axElements: ShownDocumentsProbe.elementMetrics)
                let file = session.directory.appending(path: "stage-\(sequence).json")
                try JSONEncoder().encode(stage).write(to: file, options: .atomic)
                // No UI action is sent by the AX client. It only confirms that this precise stage was read.
                let ack = session.directory.appending(path: "ack-\(sequence)")
                try await wait("AX reader at " + phase) {
                    (try? String(contentsOf: ack, encoding: .utf8)) == session.token
                }
                sequence += 1
                try await Task.sleep(for: .milliseconds(300))
            }

            func paperReady() -> Bool {
                model.mode == .view && model.isUpToDate && model.paper.probeShows(model.paperDocument)
            }
            func focusPaper() {
                model.paper.attachedProbeView?.identifyProbePaper(session.token)
                model.paper.focus()
            }
            try await wait("first paper", for: paperReady)
            model.zoom = 1
            model.setLayout(.single)
            try await wait("single page") { paperReady() && model.paper.attachedProbeView?.probeLayout == .single }
            NSApp.activate()
            model.window?.makeKeyAndOrderFront(nil)
            try await wait("fixture window focus") { NSApp.isActive && model.window?.isKeyWindow == true }
            focusPaper()
            try await publish("initial", generation: 0)
            for iteration in 1...session.count {
                if session.operation == "layout" {
                    let next: ViewOptions.Layout = iteration.isMultiple(of: 2) ? .single : .spread
                    model.setLayout(next)
                    try await wait("layout") { paperReady() && model.paper.attachedProbeView?.probeLayout == next }
                    try await publish("layout", generation: iteration - 1)
                } else if session.operation == "tray" {
                    let oldID = model.paper.attachedProbeView?.probeID
                    model.enterPrintMode()
                    try await wait("tray") {
                        model.mode == .print && model.hasCurrentPrintPreview && model.paper.attachedProbeView == nil
                    }
                    try await publish("inTray", generation: iteration - 1)
                    model.exitPrintMode()
                    try await wait("returned paper") { paperReady() && model.paper.attachedProbeView?.probeID != oldID }
                    focusPaper()
                    try await publish("afterTray", generation: iteration - 1)
                }
                let previous = model.result?.id
                let expected = try writeFixture(session, generation: iteration)
                model.reload()
                try await wait("new generation") {
                    paperReady() && model.data == expected && model.result?.id != previous
                }
                try await publish("reload", generation: iteration)
            }
            try await publish("finished", generation: session.count)
            try Data(session.token.utf8).write(
                to: session.directory.appending(path: "complete"), options: .atomic)
        }
    }
#endif
