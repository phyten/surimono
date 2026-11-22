#if DEBUG
    import AppKit
    import OSLog

    @MainActor
    enum DebugSnapshotProgress {
        // Each runner-owned launch receives a different private home, including a retry of the same case.
        private static let file = ProcessInfo.processInfo.environment["SURIMONO_SNAPSHOT_STATE"]
        private static var last = ""
        private static var expired = false

        static func recordAppearance(_ appearance: NSAppearance) {
            guard let file else { return }
            let name = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
            let url = URL(fileURLWithPath: file).deletingLastPathComponent().appendingPathComponent("appearance.txt")
            try? name.write(to: url, atomically: true, encoding: .utf8)
        }

        static func report(_ stage: String) {
            guard let file, !expired, stage != last else { return }
            last = stage
            try? stage.write(toFile: file, atomically: true, encoding: .utf8)
        }

        static func start() {
            report("Waiting for document window and initial render")
            guard file != nil, DebugSnapshot.argument("SurimonoSettings") != nil else { return }
            Task {
                do { try await Task.sleep(for: .seconds(50)) } catch { return }
                deadline(last)
            }
        }

        private static func deadline(_ stage: String) {
            report("deadline: " + stage)
            expired = true
        }

        static func failed(_ error: Error) {
            let message = error.localizedDescription
            Logger(subsystem: "app.surimono.Surimono.debug", category: "Snapshot").error(
                "\(message, privacy: .public)")
            if let timeout = error as? SnapshotDeadline, file != nil {
                // Keep the process alive for the runner to sample before termination.
                deadline(timeout.stage)
            } else {
                report("issue: " + message)
                if DebugSnapshot.flag("SurimonoSnapshotQuit") { exit(EXIT_FAILURE) }
            }
        }

    }
#endif
