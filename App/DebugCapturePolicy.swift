#if DEBUG || SWIFT_PACKAGE
    import Foundation
    import ImageIO
    import UniformTypeIdentifiers

    struct CaptureObservation: Codable, Equatable, Sendable {
        let isKeyWindow: Bool
        let appActive: Bool
        let attempts: Int
        let stable: Bool
        var readinessIssue: String? = nil

        // Keep the observations with the exact pixels they describe, including after a file rename.
        func png(image: CGImage, scale: CGFloat) throws -> Data {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
            else { throw CocoaError(.fileWriteUnknown) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let description = String(decoding: try encoder.encode(self), as: UTF8.self)
            CGImageDestinationAddImage(
                destination, image,
                [
                    kCGImagePropertyDPIWidth: scale * 72, kCGImagePropertyDPIHeight: scale * 72,
                    kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description],
                ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            return data as Data
        }

        static func read(pngProperties properties: [String: Any]) throws -> Self {
            guard let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any],
                let description = png[kCGImagePropertyPNGDescription as String] as? String
            else { throw CocoaError(.fileReadCorruptFile) }
            return try JSONDecoder().decode(Self.self, from: Data(description.utf8))
        }
    }

    /// ScreenCaptureKit frames have a top-left origin; Quartz draws from the bottom left.
    struct CaptureGeometry {
        let size: CGSize
        let destinations: [CGRect]

        init?(root: CGRect, layers: [CGRect], scale: CGFloat) {
            guard scale.isFinite, scale > 0, !layers.isEmpty else { return nil }
            // Quantize offsets from the root, never global screen coordinates.
            let pixels = layers.map {
                CGRect(
                    x: (($0.minX - root.minX) * scale).rounded(),
                    y: (($0.minY - root.minY) * scale).rounded(),
                    width: ($0.width * scale).rounded(), height: ($0.height * scale).rounded())
            }
            guard pixels.allSatisfy({ !$0.isEmpty && !$0.isInfinite && !$0.isNull }) else { return nil }
            let union = pixels.reduce(CGRect.null) { $0.union($1) }
            size = union.size
            destinations = pixels.map {
                CGRect(x: $0.minX - union.minX, y: union.maxY - $0.maxY, width: $0.width, height: $0.height)
            }
        }

        func makeCanvas() throws -> CGContext {
            guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                let canvas = CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height),
                    bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4, space: color,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw CocoaError(.fileReadCorruptFile) }
            // Use the same opaque sRGB gray behind every transparent corner and popover.
            canvas.setFillColor(red: 0.88, green: 0.88, blue: 0.88, alpha: 1)
            canvas.fill(CGRect(origin: .zero, size: size))
            return canvas
        }
    }

    struct CaptureFrame {
        let image: CGImage
        let pixels: CFData
        let scale: CGFloat
        let key: Bool
        let active: Bool
        let complete: Bool

        func matches(_ other: CaptureFrame) -> Bool {
            image.width == other.image.width && image.height == other.image.height
                && CFEqual(pixels, other.pixels)
        }
    }

    struct SnapshotDeadline: LocalizedError {
        let stage: String
        var errorDescription: String? { "Timed out waiting for " + stage }
    }

    enum CaptureSequence {
        // ScreenCaptureKit may never resume its async call. A task group would join that call on timeout.
        @MainActor static func bounded<T>(
            _ stage: String, limit: Duration, operation: @escaping @MainActor () async throws -> T
        ) async throws -> T {
            let (signal, completion) = AsyncStream<Void>.makeStream()
            var result: Result<T, Error>?
            let work = Task {
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                completion.finish()
            }
            let timer = Task {
                try await Task.sleep(for: limit)
                completion.finish()
            }
            defer {
                timer.cancel()
                work.cancel()
            }
            for await _ in signal {}
            guard let result else { throw SnapshotDeadline(stage: stage) }
            return try result.get()
        }

        /// Require two pixel-identical consecutive frames. Return the last frame for diagnosis on exhaustion.
        @MainActor static func settle<Frame>(
            capture: () async throws -> Frame,
            matches: (Frame, Frame) -> Bool,
            pause: () async throws -> Void
        ) async throws -> (frame: Frame, attempts: Int, stable: Bool) {
            var last = try await capture()
            for attempt in 2...5 {
                try await pause()
                let next = try await capture()
                if matches(last, next) { return (next, attempt, true) }
                last = next
            }
            return (last, 5, false)
        }
    }
#endif
