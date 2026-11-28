import CoreGraphics
import Foundation
import Observation
import SurimonoRendering

struct PageScrubImageKey: Hashable {
    let generation: Int
    let page: Int
    let pixels: Int
}

@Observable
final class PageScrubSession {
    var frame: CGRect = .zero {
        didSet {
            // A slider that moves or changes width under a held pointer would point at another page than the one the
            // reader aimed at (the band shares its room with the chapter title): let the drag go instead.
            guard dragging, abs(frame.minX - pressFrame.minX) > 0.5 || abs(frame.width - pressFrame.width) > 0.5
            else { return }
            cancel()
        }
    }
    @ObservationIgnored private var pressFrame: CGRect = .zero
    private(set) var bitmap: (PageScrubImageKey, CGImage)?
    private(set) var fraction: CGFloat?
    private(set) var showsPreview = false
    private(set) var dragging = false
    var keyboardFocus = false
    var voiceOverFocus = false
    private(set) var pointerActive = false
    var holdsBand: Bool { pointerActive || keyboardFocus || voiceOverFocus }
    @ObservationIgnored private var delay: Task<Void, Never>?

    func point(_ position: CGFloat, immediately: Bool = false) {
        if !pointerActive { pointerActive = true }
        fraction = min(1, max(0, position))
        if immediately {
            delay?.cancel()
            delay = nil
            showsPreview = true
        } else if delay == nil && !showsPreview {
            delay = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                self?.showsPreview = true
                self?.delay = nil
            }
        }
    }

    func load(_ request: PageScrubImageKey?, from cache: PageThumbnails?) async {
        guard !Task.isCancelled else { return }
        bitmap = nil
        guard let request, let cache, let image = await cache.scrubImage(page: request.page, pixels: request.pixels),
            !Task.isCancelled
        else { return }
        bitmap = (request, image)
    }

    func press(_ fraction: CGFloat) {
        pressFrame = frame
        dragging = true
        point(fraction, immediately: true)
    }

    func release(_ position: CGFloat, inside: Bool) -> CGFloat? {
        guard dragging else { return nil }
        dragging = false
        point(position, immediately: true)
        let target = fraction
        if !inside { cancel() }
        return target
    }

    func leave() {
        if !dragging { cancel() }
    }

    func cancel() {
        delay?.cancel()
        delay = nil
        pointerActive = false
        fraction = nil
        bitmap = nil
        showsPreview = false
        dragging = false
    }
}
