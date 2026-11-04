import CoreGraphics
import Foundation
import SurimonoCore

extension NotePaperCanvas {
    func decorations(overlay: Bool) {
        if overlay {
            switch style.decoration {
            case .none, .minutes, .gingham, .mizutama, .stripe: return
            default: break
            }
        } else {
            switch style.decoration {
            case .hoshizora:
                fade("#8F80C4", alpha: 0.16, fraction: 0.2)
                return
            case .kumo:
                fade("#8FB6D9", alpha: 0.2, fraction: 0.17)
                return
            case .ichigo, .ribbon, .nikukyu, .hana: return
            default: break
            }
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(0.3)
        switch style.decoration {
        case .none, .minutes: break
        case .gingham:
            context.setFillColor(Self.color("#E58CA5") ?? CGColor(gray: 0.7, alpha: 1))
            context.setAlpha(0.3)
            for x in stride(from: 0.0, to: width, by: 6.8) {
                context.fill(CGRect(x: x, y: 0, width: 3.4, height: height))
            }
            for y in stride(from: 0.0, to: height, by: 6.8) {
                context.fill(CGRect(x: 0, y: y, width: width, height: 3.4))
            }
            context.setAlpha(1)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.addPath(
                CGPath(
                    roundedRect: CGRect(x: 11, y: 11, width: width - 22, height: height - 22),
                    cornerWidth: 5, cornerHeight: 5, transform: nil))
            context.fillPath()
            context.setStrokeColor(Self.color("#E59AAE") ?? CGColor(gray: 0.7, alpha: 1))
            context.setLineDash(phase: 0, lengths: [1.6, 1.2])
            context.addPath(
                CGPath(
                    roundedRect: CGRect(x: 13, y: 13, width: width - 26, height: height - 26),
                    cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.strokePath()
        case .mizutama:
            context.setFillColor(Self.color("#7FAAD6") ?? CGColor(gray: 0.7, alpha: 1))
            context.setAlpha(0.3)
            for y in stride(from: 0.0, through: height, by: 8) {
                let offset = Int(y / 8).isMultiple(of: 2) ? 0.0 : 8.0
                for x in stride(from: offset, through: width, by: 16) {
                    context.fillEllipse(in: CGRect(x: x - 2.3, y: y - 2.3, width: 4.6, height: 4.6))
                }
            }
        case .stripe:
            context.setFillColor(Self.color("#A99BD1") ?? CGColor(gray: 0.7, alpha: 1))
            context.setAlpha(0.17)
            for x in stride(from: 0.0, to: width, by: 10) {
                context.fill(CGRect(x: x, y: 0, width: 5, height: height))
            }
        case .ichigo:
            row(count: width > 160 ? 6 : 4, from: 20, to: width - 20) { x, index in
                motif(
                    .berry, x: x, y: 15 + CGFloat(index % 2) * 3, size: index.isMultiple(of: 2) ? 19 : 15,
                    rotation: index.isMultiple(of: 2) ? -12 : 12)
            }
            motif(.berry, x: width - 20, y: height - 18, size: 20, rotation: 12)
            motif(.berry, x: width - 38, y: height - 12, size: 12, rotation: -14)
        case .hoshizora:
            motif(.moon, x: 25, y: 18, size: 22, rotation: -6)
            let stars: [(CGFloat, CGFloat, CGFloat)] = [
                (50, 12, 8), (66, 22, 6), (84, 11, 7),
                (102, 20, 9), (122, 12, 5.5), (144, 21, 7), (168, 12, 9), (190, 19, 5.5),
            ]
            context.setStrokeColor(Self.color("#8F80C4") ?? CGColor(gray: 0.5, alpha: 1))
            context.setLineDash(phase: 0, lengths: [0.8, 1])
            for index in 0..<3 {
                line(stars[index].0, stars[index].1, stars[index + 1].0, stars[index + 1].1)
            }
            context.setLineDash(phase: 0, lengths: [])
            for (index, star) in stars.enumerated() where star.0 < width - 10 {
                motif(index.isMultiple(of: 2) ? .star : .filledStar, x: star.0, y: star.1, size: star.2)
            }
            motif(.star, x: width - 20, y: height - 16, size: 10, rotation: 10)
            motif(.filledStar, x: width - 36, y: height - 10, size: 6, rotation: -14)
        case .kumo:
            motif(.cloud, x: 30, y: 16, size: 26)
            motif(.cloud, x: width / 2, y: 11, size: 16)
            motif(.cloud, x: width - 34, y: 18, size: 21)
            motif(.cloud, x: width - 26, y: height - 15, size: 22)
            motif(.cloud, x: width - 58, y: height - 10, size: 12)
        case .ribbon:
            context.setStrokeColor(Self.color("#E59AAE") ?? CGColor(gray: 0.5, alpha: 1))
            for y in [13.0, 15.6] {
                line(12, y, width / 2 - 13, y)
                line(width / 2 + 13, y, width - 12, y)
            }
            context.setLineDash(phase: 0, lengths: [1.3, 1.1])
            line(12, 14.3, width / 2 - 13, 14.3)
            line(width / 2 + 13, 14.3, width - 12, 14.3)
            line(12, height - 12, width - 12, height - 12)
            context.setLineDash(phase: 0, lengths: [])
            motif(.bow, x: width / 2, y: 16, size: 28)
        case .nikukyu:
            motif(.paw, x: 20, y: 18, size: 15, rotation: -18)
            motif(.paw, x: 38, y: 12, size: 12, rotation: 14)
            for index in 0..<4 {
                motif(
                    .paw, x: width - 62 + CGFloat(index) * 16, y: height - (index.isMultiple(of: 2) ? 11 : 18),
                    size: 11 + CGFloat(index), rotation: index.isMultiple(of: 2) ? 22 : -10)
            }
        case .hana:
            let kinds: [NotePaperMotif] = [.flower, .leaf, .purpleFlower, .leaf]
            row(count: max(2, Int((width - 16) / 17)), from: 9, to: width - 9) { x, index in
                let top = kinds[index % 4]
                let bottom = kinds[(index + 2) % 4]
                motif(top, x: x, y: 9, size: top == .leaf ? 8 : 12, rotation: CGFloat(index * 22))
                motif(bottom, x: x, y: height - 9, size: bottom == .leaf ? 8 : 12, rotation: CGFloat(index * -22))
            }
            row(count: max(2, Int((height - 34) / 17)), from: 26, to: height - 26) { y, index in
                let left = kinds[(index + 1) % 4]
                let right = kinds[(index + 3) % 4]
                motif(left, x: 9, y: y, size: left == .leaf ? 8 : 12, rotation: CGFloat(index * 30))
                motif(right, x: width - 9, y: y, size: right == .leaf ? 8 : 12, rotation: CGFloat(index * -30))
            }
        }
    }

    private func row(count: Int, from: CGFloat, to: CGFloat, draw: (CGFloat, Int) -> Void) {
        for index in 0..<count { draw(from + (to - from) * CGFloat(index) / CGFloat(max(1, count - 1)), index) }
    }

    private func fade(_ hex: String, alpha: CGFloat, fraction: CGFloat) {
        guard let color = Self.color(hex), let start = color.copy(alpha: alpha), let end = color.copy(alpha: 0),
            let gradient = CGGradient(
                colorsSpace: color.colorSpace, colors: [start, end] as CFArray, locations: [0, 1])
        else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height * fraction), options: [])
    }
}
