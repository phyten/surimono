// Draws numbered callouts on a screenshot for a pull request: a red frame around each region and a numbered badge
// with a short label next to it. Uses only CoreGraphics and AppKit, which every Mac has.
//
// Usage: swift annotate-screenshot.swift <input.png> <output.png> "<x>,<y>,<width>,<height>:<label>" ...
// Coordinates are in the image's pixels from the top left corner.
import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    FileHandle.standardError.write(
        Data("usage: annotate-screenshot.swift <input.png> <output.png> \"x,y,w,h:label\" ...\n".utf8))
    exit(2)
}
guard let source = NSImage(contentsOfFile: arguments[1]),
    let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("cannot read \(arguments[1])\n".utf8))
    exit(1)
}
let width = image.width
let height = image.height
guard
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
// Flip so callout coordinates read from the top left, like the screenshot itself.
context.translateBy(x: 0, y: CGFloat(height))
context.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

let red = NSColor(srgbRed: 0.85, green: 0.16, blue: 0.13, alpha: 1)
let scale = max(CGFloat(width) / 1600, 1)
for (index, spec) in arguments.dropFirst(3).enumerated() {
    let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let fields = (parts.first ?? "").split(separator: ",", omittingEmptySubsequences: false)
    let numbers = fields.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard fields.count == 4, numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 else {
        FileHandle.standardError.write(Data("bad region (want x,y,width,height[:label]): \(spec)\n".utf8))
        exit(2)
    }
    let rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    context.setStrokeColor(red.cgColor)
    context.setLineWidth(4 * scale)
    context.stroke(rect.insetBy(dx: -2 * scale, dy: -2 * scale))
    // A numbered badge on the frame's top left corner, and the label beside it on a white plate.
    let badge = CGRect(x: rect.minX - 14 * scale, y: rect.minY - 14 * scale, width: 28 * scale, height: 28 * scale)
    context.setFillColor(red.cgColor)
    context.fillEllipse(in: badge)
    let numberAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 16 * scale), .foregroundColor: NSColor.white,
    ]
    let number = NSAttributedString(string: "\(index + 1)", attributes: numberAttributes)
    let numberSize = number.size()
    number.draw(at: CGPoint(x: badge.midX - numberSize.width / 2, y: badge.midY - numberSize.height / 2))
    guard parts.count == 2, !parts[1].isEmpty else { continue }
    let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 15 * scale), .foregroundColor: red,
    ]
    let label = NSAttributedString(string: parts[1], attributes: labelAttributes)
    let labelSize = label.size()
    var origin = CGPoint(x: badge.maxX + 6 * scale, y: badge.midY - labelSize.height / 2)
    origin.x = min(origin.x, CGFloat(width) - labelSize.width - 8 * scale)
    origin.y = max(origin.y, 4 * scale)
    let plate = CGRect(origin: origin, size: labelSize).insetBy(dx: -6 * scale, dy: -3 * scale)
    context.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
    context.fill(plate)
    context.setStrokeColor(red.cgColor)
    context.setLineWidth(1.5 * scale)
    context.stroke(plate)
    label.draw(at: origin)
}

guard let output = context.makeImage(),
    let data = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
else { exit(1) }
do {
    try data.write(to: URL(fileURLWithPath: arguments[2]))
} catch {
    FileHandle.standardError.write(Data("cannot write \(arguments[2])\n".utf8))
    exit(1)
}
