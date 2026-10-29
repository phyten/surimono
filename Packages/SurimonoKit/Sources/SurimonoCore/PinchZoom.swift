import Foundation

public enum PinchZoom {
    /// Resists closing below fit, with half the initial log-scale response and an asymptote at 80%.
    public static func rubberBand(_ zoom: Double) -> Double {
        guard zoom < 1 else { return zoom }
        guard zoom > 0 else { return 0.8 }
        let limit = log(1 / 0.8)
        let compression = -log(zoom) * 0.5
        return exp(-limit * compression / (limit + compression))
    }

    /// Inverts the resistance so a new pinch can interrupt a rubber return without jumping.
    public static func fingerZoom(for displayedZoom: Double) -> Double {
        guard displayedZoom < 1 else { return displayedZoom }
        guard displayedZoom > 0.8 else { return Double.leastNormalMagnitude }
        let limit = log(1 / 0.8)
        let compression = -log(displayedZoom)
        return exp(-2 * limit * compression / (limit - compression))
    }

    /// Logarithmic ease-out and a fixed-point scaling path that lands exactly at the fitted position.
    public struct Return: Sendable {
        public static let duration = 0.28
        public let startZoom: Double

        public init(startZoom: Double) {
            self.startZoom = startZoom
        }

        public func zoom(elapsed: Double) -> Double {
            guard elapsed > 0 else { return startZoom }
            guard elapsed < Self.duration else { return 1 }
            return exp(log(startZoom) * pow(1 - elapsed / Self.duration, 3))
        }

        /// Apply to either coordinate of the same paper point at the start and at fit. This is equivalent to
        /// scaling around (startZoom * end - start) / (startZoom - 1), without a near-fit unstable anchor.
        /// If the paper covers the viewport at both ends, its edges cover it throughout this interpolation.
        public func position(start: Double, end: Double, zoom: Double) -> Double {
            guard startZoom != 1 else { return end }
            return end + (start - end) * ((zoom - 1) / (startZoom - 1))
        }
    }
}
