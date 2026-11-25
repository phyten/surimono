#if DEBUG
    import CoreGraphics
    import Foundation
    import Testing

    @testable import Surimono

    @MainActor struct DebugPageAXStageTests {
        typealias Stage = DebugPageAXSession.Stage

        private func stage(second bounds: CGRect, point: CGPoint = .zero) -> Stage {
            let first = CGRect(x: 40, y: 80, width: 12, height: 14)
            return Stage(
                pid: 42, token: "fixture", operation: "layout", count: 10, sequence: 2, phase: "layout", generation: 0,
                hit: .init(
                    point: point, page: "page.0", mouseHitsPaper: true, paperHitIdentifier: "page.0",
                    windowIsPaperAncestor: false, windowRole: nil, windowIdentifier: nil),
                pages: [
                    .init(identifier: "page.0", characterIndex: 6, characterBounds: first),
                    .init(identifier: "page.1", characterIndex: 0, characterBounds: bounds),
                ],
                axElements: .init(
                    leaves: [], firstTextSeconds: nil, totalTextSeconds: 0, totalSnapshotSeconds: 0,
                    extractedCount: 0, liveCount: 0, liveEstimatedBytes: 0))
        }

        @Test("先頭ページにヒットしても次ページの枠が無限なら、段を書かず項目と値を知らせる")
        func invalidSecondPage() async throws {
            let sample = stage(second: .null)
            #expect(throws: EncodingError.self) { try JSONEncoder().encode(sample) }
            do {
                _ = try await Stage.encodeWhenReady(within: .zero) { sample }
                Issue.record("Expected a non-finite page bound")
            } catch let issue as DebugPageAXSession.StageIssue {
                #expect(issue.kind == .nonFinite)
                #expect(issue.field == "pages[1].characterBounds.origin.x")
                #expect(issue.value == "inf")
                let directory = FileManager.default.temporaryDirectory
                let session = DebugPageAXSession.Session(
                    directory: directory, fixture: directory.appending(path: "Paper.md"), operation: "layout", count: 10
                )
                let failure = DebugPageAXSession.AppFailure(
                    session: session, sequence: 2, phase: "layout", error: issue)
                let json = try #require(
                    JSONSerialization.jsonObject(with: JSONEncoder().encode(failure)) as? [String: Any])
                #expect(json["sequence"] as? Int == 2)
                #expect(json["kind"] as? String == "nonFinite")
                #expect(json["field"] as? String == "pages[1].characterBounds.origin.x")
                #expect(json["value"] as? String == "inf")
            }
        }

        @Test("紙に戻った直後の座標が非数なら、次の有限な試料だけを書き出す")
        func retriesPoint() async throws {
            let box = CGRect(x: 10, y: 20, width: 12, height: 14)
            let invalid = stage(second: box, point: CGPoint(x: CGFloat.nan, y: 25))
            #expect(throws: EncodingError.self) { try JSONEncoder().encode(invalid) }
            var reads = 0
            let data = try await Stage.encodeWhenReady {
                reads += 1
                return reads == 1 ? invalid : stage(second: box, point: CGPoint(x: 12, y: 25))
            }
            #expect(reads == 2)
            let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let hit = try #require(json["hit"] as? [String: Any])
            #expect(hit["point"] as? [Double] == [12, 25])
        }
    }
#endif
