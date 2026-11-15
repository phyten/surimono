import CoreImage
import QuartzCore

/// How the page curl turns a page: a soft sheet peeled from its outer bottom corner that settles lightly ("perorin").
/// The values that make the feel are here together, so that the turn can be made livelier or calmer later.
struct PageCurl: Equatable {
    /// The whole turn, in seconds. Longer reads as heavier paper; much longer gets in the way of turning many pages.
    static let duration = 0.5
    /// Progress over time: a quick peel at the start ("pero") and a long, soft landing ("rin"). The first two values
    /// make the start brisker, the last two the landing softer.
    static let timing = CAMediaTimingFunction(controlPoints: 0.3, 0.5, 0.3, 1)
    /// How far the peel runs off the horizontal, in radians. Zero rolls the page in flat from its side; more lifts it
    /// from the corner and peels it diagonally.
    static let lift = 0.42
    /// The radius of the curl as a share of the page's shorter side, so that small and large paper peel alike.
    /// Larger is a rounder, softer sheet; smaller a tighter, stiffer one.
    static let radiusShare = 0.2
    /// The back of the paper, a pale warm white rather than the mirrored text of the front.
    static let backside = CIColor(red: 0.97, green: 0.96, blue: 0.93)
    /// The shadow the lifted sheet casts on the page beneath: its width (0 to 1) and how dark it is (0 to 1).
    static let shadowSize = 0.45
    static let shadowAmount = 0.22

    /// The direction of the peel, in radians as Core Image measures it.
    let angle: Double

    /// - Parameters:
    ///   - forward: Turning to the next page.
    ///   - nextFromRight: The next page lies to the right, as in a book read from left to right.
    init(forward: Bool, nextFromRight: Bool) {
        // Core Image peels from the side the angle points away from, so the angle points across the page and slightly
        // down: the sheet rises from its lower corner. A turn forward lifts the outer corner and the sheet leaves
        // towards the binding; a turn back lifts the inner corner and it leaves the other way, so that going back
        // never looks like another turn forward. Core Animation runs only its own filters on a transition, so the page
        // turned before cannot be played coming back over this one.
        let leavesLeft = forward == nextFromRight
        angle = leavesLeft ? -.pi + Self.lift : -Self.lift
    }

    /// The radius of the curl on paper of `size`.
    static func radius(for size: CGSize) -> Double {
        Double(min(size.width, size.height)) * radiusShare
    }

    /// The filter of the turn on a layer of `extent`, or nil when Core Image does not have it.
    func filter(extent: CGRect) -> CIFilter? {
        guard let curl = CIFilter(name: "CIPageCurlWithShadowTransition") ?? CIFilter(name: "CIPageCurlTransition")
        else { return nil }
        curl.setDefaults()
        let keys = Set(curl.inputKeys)
        curl.setValue(angle, forKey: kCIInputAngleKey)
        curl.setValue(Self.radius(for: extent.size), forKey: kCIInputRadiusKey)
        curl.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        if keys.contains("inputBacksideImage") {
            curl.setValue(CIImage(color: Self.backside).cropped(to: extent), forKey: "inputBacksideImage")
        }
        if keys.contains("inputShadowSize") {
            curl.setValue(Self.shadowSize, forKey: "inputShadowSize")
            curl.setValue(Self.shadowAmount, forKey: "inputShadowAmount")
            curl.setValue(CIVector(cgRect: extent), forKey: "inputShadowExtent")
        }
        return curl
    }
}
