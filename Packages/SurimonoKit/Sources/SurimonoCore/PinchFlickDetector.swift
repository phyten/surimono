import Foundation

/// Detects a deliberate closing flick using finger zoom, before rubber-band resistance is applied.
public struct PinchFlickDetector: Sendable {
    public enum Phase: Sendable {
        case began, changed, ended, cancelled
    }

    // About six times faster than a slow 300%-to-200% pinch over one second.
    public static let velocityThreshold = -2.5
    // Averages roughly 6-12 trackpad events without hiding a deliberate flick.
    public static let sampleWindow = 0.1
    // Small, fast finger tremors should not reset the zoom.
    public static let maximumTriggerRatio = 0.85
    // Returning to fit has little value when the gesture starts almost fitted.
    public static let minimumStartZoom = 1.05

    private struct Sample: Sendable {
        let time: Double
        let logZoom: Double
    }

    private var samples: [Sample] = []
    private var startZoom: Double = 1
    private var active = false
    private var triggered = false

    public init() {}

    public mutating func update(timestamp: Double, zoom: Double, phase: Phase) -> Bool {
        if phase == .cancelled {
            active = false
            return false
        }
        guard timestamp.isFinite, zoom.isFinite, zoom > 0 else { return false }
        if phase == .began {
            samples = [Sample(time: timestamp, logZoom: log(zoom))]
            startZoom = zoom
            active = true
            triggered = false
            return false
        }
        defer { if phase == .ended { active = false } }
        guard active, !triggered, let last = samples.last, timestamp > last.time else { return false }
        let current = Sample(time: timestamp, logZoom: log(zoom))
        samples.append(current)
        let cutoff = timestamp - Self.sampleWindow
        // Keep the sample just before the window so irregular event times can be interpolated.
        while samples.count > 2 && samples[1].time <= cutoff { samples.removeFirst() }
        let first = samples[0]
        let baselineTime = max(cutoff, first.time)
        var baseline = first.logZoom
        if baselineTime > first.time {
            let next = samples[1]
            let fraction = (baselineTime - first.time) / (next.time - first.time)
            baseline += (next.logZoom - first.logZoom) * fraction
        }
        let velocity = (current.logZoom - baseline) / (timestamp - baselineTime)
        triggered =
            startZoom > Self.minimumStartZoom && zoom / startZoom <= Self.maximumTriggerRatio
            && velocity <= Self.velocityThreshold
        return triggered
    }
}
