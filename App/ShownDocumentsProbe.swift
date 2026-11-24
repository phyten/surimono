#if DEBUG
    import AppKit
    import Darwin

    enum ShownDocumentsProbe {
        static let path = DebugSnapshot.argument("SurimonoShownDocumentsProbe")
        // A detached paper can still own generations. Observing it must not extend its life.
        static let views = NSHashTable<PaperPDFView>.weakObjects()

        static let measuresBytes = path != nil && !DebugSnapshot.flag("SurimonoShownDocumentsProbeNoBytes")
        struct Lifetime: Encodable {
            let created: Double
            var dismantled: Double?
            var deinitialized: Double?
        }
        // A final sample must include the IDs of papers that have already gone away.
        static var lifetimes: [UUID: Lifetime] = [:]
        static let elements = NSHashTable<PageTextElement>.weakObjects()
        static var measuresElements: Bool { path != nil || DebugPageAXSession.current != nil }
        static var firstTextSeconds: Double?
        static var textSeconds = 0.0
        static var extractedCount = 0
        static var extractionSeconds = 0.0

        struct Generation: Encodable {
            let sourcePages: Int
            let displayedPages: Int
            let sharesSource: Bool
            let serializedBytes: Int?
        }

        struct ViewSample: Encodable {
            let id: UUID
            let attached: Bool
            let shownDocumentCount: Int
            let generations: [Generation]
        }

        struct ElementMetrics: Encodable {
            struct Leaf: Encodable {
                let pageIndex: Int
                let firstReadSeconds: Double?
                let estimatedBytes: Int
            }
            let leaves: [Leaf]
            let firstTextSeconds: Double?
            let totalTextSeconds: Double
            let totalSnapshotSeconds: Double
            let extractedCount: Int
            let liveCount: Int
            let liveEstimatedBytes: Int
        }

        static var elementMetrics: ElementMetrics {
            let live = elements.allObjects
            let leaves = live.map {
                ElementMetrics.Leaf(
                    pageIndex: $0.index, firstReadSeconds: $0.firstReadSeconds, estimatedBytes: $0.estimatedBytes)
            }
            return .init(
                leaves: leaves.sorted { $0.pageIndex < $1.pageIndex }, firstTextSeconds: firstTextSeconds,
                totalTextSeconds: textSeconds,
                totalSnapshotSeconds: extractionSeconds,
                extractedCount: extractedCount, liveCount: live.count,
                liveEstimatedBytes: live.reduce(0) { $0 + $1.estimatedBytes })
        }

        private struct Sample: Encodable {
            let phase: String
            let iteration: Int
            let activeViewID: UUID?
            let liveViewCount: Int
            let views: [ViewSample]
            let uptime: Double
            let lifetimes: [String: Lifetime]
            let measuresBytes: Bool
            let axElements: ElementMetrics
            let physFootprintBytes: UInt64
        }

        static func run(_ model: DocumentViewModel, path: String) async throws {
            guard path.hasPrefix("/") else { throw CocoaError(.fileWriteInvalidFileName) }
            let count = Int(DebugSnapshot.argument("SurimonoRerenderCount") ?? "50")
            guard let count, count >= 0 else { throw ProbeError("SurimonoRerenderCount must be a nonnegative integer") }
            guard DocumentViewModel.canExport(to: URL(fileURLWithPath: path), sourceURLs: model.protectedSourceURLs)
            else { throw CocoaError(.fileWriteNoPermission) }
            // Exclusive creation also protects other open documents and their hard links.
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

            func record(_ phase: String, _ iteration: Int) throws {
                let footprint = try footprintBytes()
                let samples = views.allObjects.map(\.probeSample).sorted { $0.id.uuidString < $1.id.uuidString }
                let sample = Sample(
                    phase: phase, iteration: iteration, activeViewID: model.paper.attachedProbeView?.probeID,
                    liveViewCount: samples.count, views: samples, uptime: ProcessInfo.processInfo.systemUptime,
                    lifetimes: Dictionary(uniqueKeysWithValues: lifetimes.map { ($0.key.uuidString, $0.value) }),
                    measuresBytes: measuresBytes, axElements: elementMetrics, physFootprintBytes: footprint)
                var line = try JSONEncoder().encode(sample)
                line.append(0x0A)
                try file.write(contentsOf: line)
            }

            func wait(_ stage: String, until ready: () -> Bool) async throws {
                let deadline = ContinuousClock.now + .seconds(360)
                while !ready() {
                    guard model.window != nil, model.error == nil else { throw ProbeError("Could not finish " + stage) }
                    guard ContinuousClock.now < deadline else { throw SnapshotDeadline(stage: stage) }
                    try await Task.sleep(for: .milliseconds(50))
                }
            }

            func paperIsReady() -> Bool {
                model.mode == .view && model.isUpToDate && model.paper.probeShows(model.paperDocument)
            }

            try await wait("initial paper", until: paperIsReady)
            try record("initial", 0)
            for index in 0..<count {
                let previous = model.result?.id
                model.reload()
                try await wait("reload \(index + 1)") { model.result?.id != previous && paperIsReady() }
                try record("rerender", index + 1)
            }

            let oldViewID = model.paper.attachedProbeView?.probeID
            try record("beforeTray", count)
            model.enterPrintMode()
            try await wait("print tray") {
                model.mode == .print && model.hasCurrentPrintPreview && model.paper.attachedProbeView?.probeID == nil
            }
            try record("inTray", count)
            model.exitPrintMode()
            try await wait("new paper") { paperIsReady() && model.paper.attachedProbeView?.probeID != oldViewID }
            try record("afterTray", count)
            try await Task.sleep(for: .seconds(5))
            try record("afterTraySettled", count)
            try file.close()
        }

        private struct ProbeError: LocalizedError {
            let errorDescription: String?
            init(_ description: String) { errorDescription = description }
        }

        private static func footprintBytes() throws -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard status == KERN_SUCCESS else { throw ProbeError("task_info failed (\(status))") }
            return info.phys_footprint
        }
    }
#endif
