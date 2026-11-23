#if DEBUG
    import AppKit
    import Darwin
    import SurimonoCore
    import Testing

    @testable import Surimono

    @MainActor
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["SURIMONO_BENCH_SCRUB"] == "1"), .serialized)
    struct PageScrubberWindowBenchmarks {
        private func wait(until ready: () -> Bool) async throws {
            let limit = ContinuousClock.now + .seconds(60)
            while !ready(), ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(2)) }
            try #require(ready())
        }

        private func footprint() throws -> Int64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            try #require(status == KERN_SUCCESS)
            return Int64(info.phys_footprint)
        }

        @Test("四種類の窓でホバーから縮図表示までと一秒間の横断を測る", .timeLimit(.minutes(20)))
        func windows() async throws {
            try #require(NSScreen.main != nil)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let temp = URL.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let suite = TestDefaultsSuite()
            defer {
                suite.remove()
                try? FileManager.default.removeItem(at: temp)
            }
            let preferences = AppPreferences(defaults: suite.defaults)
            preferences.menuArrangement = .split
            let library = UserLibrary(root: temp.appending(path: "Library"))
            let store = DocumentSettingsStore(directory: temp.appending(path: "Settings"))
            let booklet = root.appending(path: "Samples/booklet-demo.md")
            let deck = root.appending(path: "Snapshots/corpus/latex/083-class-beamer/main.tex")
            for (name, format, url, data) in [
                ("booklet", DocumentFormat.markdown, Optional(booklet), try Data(contentsOf: booklet)),
                ("pdf-300", .pdf, nil, TestFixtures.textPDF((1...300).map { "Binding register, leaf " + String($0) })),
                (
                    "pdf-2000", .pdf, nil,
                    TestFixtures.textPDF((1...2000).map { "Binding register, leaf " + String($0) })
                ),
                ("deck", .latex, Optional(deck), try Data(contentsOf: deck)),
            ] {
                var cold: [Double] = []
                var warm: [Double] = []
                var sweepDone = false
                let clock = ProcessInfo.processInfo
                while cold.count < 20 || !sweepDone {
                    // A fresh reading window owns a fresh generation/cache, even for the three-slide deck.
                    let model = DocumentViewModel(
                        data: data, fileURL: url, format: format, preferences: preferences,
                        library: library, settingsStore: store)
                    let controller = MemoryDocumentWindowController(model: model) {}
                    let window = try #require(controller.window)
                    defer { controller.close() }
                    window.orderFront(nil)
                    try await wait { model.isUpToDate && window.isVisible }
                    model.isBandAlwaysVisible = true
                    window.setContentSize(CGSize(width: 1180, height: 620))
                    let content = try #require(window.contentView)
                    // The frame from before the resize is still wide enough, and the band settles in more than one
                    // layout pass; events aimed with an earlier frame land on a neighbouring page.
                    var frame = CGRect.zero
                    var settled = ContinuousClock.now
                    try await wait {
                        let next = model.scrubber.frame
                        if next != frame {
                            frame = next
                            settled = .now
                        }
                        return frame.width >= 120 && content.bounds.contains(frame) && settled + .milliseconds(300) < .now
                    }
                    let y = content.isFlipped ? frame.midY : content.bounds.height - frame.midY
                    let middle = CGPoint(x: frame.midX, y: y)
                    let target = try #require(
                        content.hitTest(content.convert(middle, to: content.superview)) as? ScrubPointer.Input)
                    func event(_ kind: NSEvent.EventType, at fraction: CGFloat) throws -> NSEvent {
                        let point = content.convert(CGPoint(x: frame.minX + fraction * frame.width, y: y), to: nil)
                        return try #require(
                            NSEvent.mouseEvent(
                                with: kind, location: point, modifierFlags: [], timestamp: clock.systemUptime,
                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                pressure: 0))
                    }
                    let track = model.pageTrack
                    let generation = try #require(model.thumbnailGeneration)
                    var shown: (Int, Double)?
                    model.scrubThumbnailReady = { id, page in
                        if id == generation { shown = (page, clock.systemUptime) }
                    }
                    if !sweepDone {
                        let cache = try #require(model.thumbnails(for: generation))
                        let before = try footprint()
                        let start = clock.systemUptime
                        let original = model.currentPageIndex
                        target.mouseDown(with: try event(.leftMouseDown, at: 0))
                        try #require(model.scrubber.dragging)
                        var last = start
                        var longest = 0.0
                        repeat {
                            let now = clock.systemUptime
                            longest = max(longest, (now - last) * 1000)
                            last = now
                            target.mouseDragged(with: try event(.leftMouseDragged, at: min(1, now - start)))
                            if now >= start + 1 { break }
                            try await Task.sleep(for: .milliseconds(4))
                        } while true
                        try await wait { shown?.0 == track.page(at: 1) }
                        let delta = try footprint() - before
                        print(
                            "SCRUB window sweep \(name) maxMainGapMS=\(longest) started=\(await cache.rendersStarted) finished=\(await cache.rendersFinished) footprintDelta=\(delta) bitmapBytes=\(await cache.byteCount)"
                        )
                        #expect(model.currentPageIndex == original && !model.pageHistory.canGoBack)
                        #expect(longest < 100)
                        #expect(await cache.rendersStarted <= 32)
                        sweepDone = true
                    } else {
                        let samples = min(20 - cold.count, track.count)
                        for i in 0..<samples {
                            let position = CGFloat(i) / CGFloat(max(1, samples - 1))
                            let page = try #require(track.page(at: position))
                            for cached in [false, true] {
                                model.scrubber.cancel()
                                try await Task.sleep(for: .milliseconds(40))
                                shown = nil
                                let start = clock.systemUptime
                                target.mouseMoved(with: try event(.mouseMoved, at: position))
                                try await wait { shown?.0 == page }
                                let ms = ((try #require(shown)).1 - start) * 1000
                                if cached { warm.append(ms) } else { cold.append(ms) }
                            }
                        }
                    }
                }
                func p(_ values: [Double], _ fraction: Double) -> Double {
                    values.sorted()[Int(ceil(Double(values.count) * fraction)) - 1]
                }
                print(
                    "SCRUB window hover \(name) n=\(cold.count) cold50=\(p(cold, 0.5)) cold95=\(p(cold, 0.95)) warm50=\(p(warm, 0.5)) warm95=\(p(warm, 0.95))"
                )
                #expect(p(cold, 0.95) <= 200)
            }
        }
    }
#endif
