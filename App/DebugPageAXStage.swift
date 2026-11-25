#if DEBUG
    import CoreGraphics
    import Foundation

    extension DebugPageAXSession {
        struct PageReference: Encodable {
            let identifier: String
            let characterIndex: Int
            let characterBounds: CGRect?
            var referenceSource: String?
            var elementCharacterBounds: CGRect?
            var referenceUnavailable: String?
        }

        struct NativeFocus: Encodable {
            let windowIdentifier: String?
            let responder: String
            let isPaper: Bool
            let isKeyWindow: Bool
            let isAppActive: Bool
        }

        struct HitTarget: Encodable {
            let point: CGPoint
            let page: String
            let mouseHitsPaper: Bool
            let paperHitIdentifier: String?
            let windowIsPaperAncestor: Bool
            var reachesPage: Bool { mouseHitsPaper && paperHitIdentifier == page }
            let windowRole: String?
            let windowIdentifier: String?
        }

        struct Stage: Encodable {
            let pid: Int32
            let token: String
            let operation: String
            let count: Int
            let sequence: Int
            let phase: String
            let generation: Int
            let hit: HitTarget?
            let pages: [PageReference]
            let axElements: ShownDocumentsProbe.ElementMetrics
            var nativeFocus: NativeFocus?

            @MainActor static func encodeWhenReady(within timeout: Duration = .seconds(5), sample: () throws -> Self)
                async throws
                -> Data
            {
                let deadline = ContinuousClock.now + timeout
                while true {
                    do {
                        let stage = try sample()
                        if stage.pages.contains(where: { $0.referenceUnavailable != nil }),
                            ContinuousClock.now < deadline
                        {
                            try await Task.sleep(for: .milliseconds(50))
                            continue
                        }
                        return try stage.encoded()
                    } catch let issue as StageIssue where issue.canRetry && ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
            }

            func encoded() throws -> Data {
                for (index, page) in pages.enumerated() {
                    if let bounds = page.characterBounds {
                        try StageIssue.check(bounds, field: "pages[\(index)].characterBounds")
                    } else if page.referenceUnavailable?.isEmpty != false || page.elementCharacterBounds == nil {
                        throw StageIssue(
                            kind: .geometryNotReady, field: "pages[\(index)]", value: "missing marker bounds")
                    }
                    if let element = page.elementCharacterBounds {
                        try StageIssue.check(element, field: "pages[\(index)].elementCharacterBounds")
                    }
                }
                if let hit { try StageIssue.check(hit.point, field: "hit.point") }
                do {
                    return try JSONEncoder().encode(self)
                } catch EncodingError.invalidValue(let value, let context) {
                    let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
                    throw StageIssue(
                        kind: .encoding, field: path.joined(separator: "."), value: String(describing: value))
                }
            }
        }

        struct StageIssue: Error {
            enum Kind: String { case nonFinite, geometryNotReady, encoding }
            let kind: Kind
            let field: String
            let value: String

            var canRetry: Bool { kind != .encoding }

            static func check(_ point: CGPoint, field: String) throws {
                try check(point.x, field: field + ".x")
                try check(point.y, field: field + ".y")
            }

            static func check(_ rect: CGRect, field: String) throws {
                try check(rect.origin, field: field + ".origin")
                try check(rect.size.width, field: field + ".size.width")
                try check(rect.size.height, field: field + ".size.height")
                // CGRect.infinite is a sentinel even on platforms where its stored components are finite.
                guard !rect.isInfinite else {
                    throw Self(kind: .geometryNotReady, field: field, value: "CGRect.infinite")
                }
                guard !rect.isEmpty else {
                    throw Self(kind: .geometryNotReady, field: field, value: "empty rectangle")
                }
            }

            private static func check(_ number: CGFloat, field: String) throws {
                guard number.isFinite else {
                    throw Self(kind: .nonFinite, field: field, value: String(describing: number))
                }
            }
        }

        struct AppFailure: Encodable, LocalizedError {
            let pid: Int32
            let token: String
            let sequence: Int
            let phase: String
            let kind: String
            let field: String
            let value: String

            init(session: Session, sequence: Int, phase: String, error: Error) {
                pid = getpid()
                token = session.token
                self.sequence = sequence
                self.phase = phase
                if let issue = error as? StageIssue {
                    (kind, field, value) = (issue.kind.rawValue, issue.field, issue.value)
                } else {
                    let cause = error as NSError
                    kind = "\(cause.domain)(\(cause.code))"
                    field = (cause.userInfo[NSFilePathErrorKey] as? String) ?? phase
                    value = error.localizedDescription
                }
            }

            var errorDescription: String? { "Stage \(sequence) (\(phase)): \(kind) at \(field): \(value)" }
        }
    }
#endif
