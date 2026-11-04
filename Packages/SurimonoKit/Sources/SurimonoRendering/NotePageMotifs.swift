import CoreGraphics
import Foundation

@MainActor
enum NotePaperMotif {
    case berry, star, filledStar, moon, cloud, paw, flower, purpleFlower, leaf, bow
}

extension NotePaperCanvas {
    func motif(_ motif: NotePaperMotif, x: CGFloat, y: CGFloat, size: CGFloat, rotation: CGFloat = 0) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: x, y: y)
        context.rotate(by: rotation * .pi / 180)
        context.scaleBy(x: size / 10, y: size / 10)
        context.translateBy(x: -5, y: -5)
        context.setLineWidth(0.34 / (size / 10))
        context.setLineCap(.round)
        switch motif {
        case .berry:
            paint(fill: "#FBE1E6", stroke: "#D9738A") {
                context.move(to: CGPoint(x: 5.0, y: 3.1))
                context.addCurve(
                    to: CGPoint(x: 8.9, y: 5.2), control1: CGPoint(x: 6.9, y: 2.3), control2: CGPoint(x: 9.0, y: 3.2))
                context.addCurve(
                    to: CGPoint(x: 5.0, y: 9.8), control1: CGPoint(x: 8.8, y: 7.2), control2: CGPoint(x: 6.5, y: 9.4))
                context.addCurve(
                    to: CGPoint(x: 1.1, y: 5.2), control1: CGPoint(x: 3.5, y: 9.4), control2: CGPoint(x: 1.2, y: 7.2))
                context.addCurve(
                    to: CGPoint(x: 5.0, y: 3.1), control1: CGPoint(x: 1.0, y: 3.2), control2: CGPoint(x: 3.1, y: 2.3))
                context.closePath()
            }
            paint(fill: nil, stroke: "#D9738A") {
                context.move(to: CGPoint(x: 3.4, y: 4.9))
                context.addLine(to: CGPoint(x: 3.4, y: 5.4))
                context.move(to: CGPoint(x: 5.0, y: 4.7))
                context.addLine(to: CGPoint(x: 5.0, y: 5.2))
                context.move(to: CGPoint(x: 6.6, y: 4.9))
                context.addLine(to: CGPoint(x: 6.6, y: 5.4))
                context.move(to: CGPoint(x: 4.2, y: 6.2))
                context.addLine(to: CGPoint(x: 4.2, y: 6.7))
                context.move(to: CGPoint(x: 5.8, y: 6.2))
                context.addLine(to: CGPoint(x: 5.8, y: 6.7))
                context.move(to: CGPoint(x: 5.0, y: 7.7))
                context.addLine(to: CGPoint(x: 5.0, y: 8.2))
            }
            paint(fill: "#E4F0DC", stroke: "#7FA65B") {
                context.move(to: CGPoint(x: 5.0, y: 3.4))
                context.addCurve(
                    to: CGPoint(x: 2.5, y: 2.7), control1: CGPoint(x: 4.2, y: 3.7), control2: CGPoint(x: 3.0, y: 3.7))
                context.addCurve(
                    to: CGPoint(x: 4.2, y: 2.1), control1: CGPoint(x: 3.3, y: 2.7), control2: CGPoint(x: 3.9, y: 2.4))
                context.addCurve(
                    to: CGPoint(x: 4.3, y: 0.7), control1: CGPoint(x: 3.8, y: 1.6), control2: CGPoint(x: 3.9, y: 1.0))
                context.addCurve(
                    to: CGPoint(x: 5.0, y: 1.9), control1: CGPoint(x: 4.7, y: 1.0), control2: CGPoint(x: 4.9, y: 1.4))
                context.addCurve(
                    to: CGPoint(x: 5.7, y: 0.7), control1: CGPoint(x: 5.1, y: 1.4), control2: CGPoint(x: 5.3, y: 1.0))
                context.addCurve(
                    to: CGPoint(x: 5.8, y: 2.1), control1: CGPoint(x: 6.1, y: 1.0), control2: CGPoint(x: 6.2, y: 1.6))
                context.addCurve(
                    to: CGPoint(x: 7.5, y: 2.7), control1: CGPoint(x: 6.1, y: 2.4), control2: CGPoint(x: 6.7, y: 2.7))
                context.addCurve(
                    to: CGPoint(x: 5.0, y: 3.4), control1: CGPoint(x: 7.0, y: 3.7), control2: CGPoint(x: 5.8, y: 3.7))
                context.closePath()
            }
        case .cloud:
            paint(fill: "#F2F8FD", stroke: "#8FB6D9") {
                context.move(to: CGPoint(x: 2.6, y: 7.6))
                context.addCurve(
                    to: CGPoint(x: 0.3, y: 5.6), control1: CGPoint(x: 1.2, y: 7.6), control2: CGPoint(x: 0.3, y: 6.7))
                context.addCurve(
                    to: CGPoint(x: 2.3, y: 3.7), control1: CGPoint(x: 0.3, y: 4.5), control2: CGPoint(x: 1.2, y: 3.7))
                context.addCurve(
                    to: CGPoint(x: 5.0, y: 1.5), control1: CGPoint(x: 2.6, y: 2.3), control2: CGPoint(x: 3.7, y: 1.5))
                context.addCurve(
                    to: CGPoint(x: 7.6, y: 3.5), control1: CGPoint(x: 6.3, y: 1.5), control2: CGPoint(x: 7.3, y: 2.3))
                context.addCurve(
                    to: CGPoint(x: 9.7, y: 5.5), control1: CGPoint(x: 8.8, y: 3.4), control2: CGPoint(x: 9.7, y: 4.3))
                context.addCurve(
                    to: CGPoint(x: 7.6, y: 7.6), control1: CGPoint(x: 9.7, y: 6.7), control2: CGPoint(x: 8.8, y: 7.6))
                context.closePath()
            }
        case .paw:
            paint(fill: "#F6EADD", stroke: "#B08A5E") {
                context.move(to: CGPoint(x: 5.0, y: 5.2))
                context.addCurve(
                    to: CGPoint(x: 7.7, y: 7.6), control1: CGPoint(x: 6.5, y: 5.2), control2: CGPoint(x: 7.7, y: 6.4))
                context.addCurve(
                    to: CGPoint(x: 6.1, y: 8.7), control1: CGPoint(x: 7.7, y: 8.5), control2: CGPoint(x: 6.9, y: 8.9))
                context.addCurve(
                    to: CGPoint(x: 3.9, y: 8.7), control1: CGPoint(x: 5.4, y: 8.5), control2: CGPoint(x: 4.6, y: 8.5))
                context.addCurve(
                    to: CGPoint(x: 2.3, y: 7.6), control1: CGPoint(x: 3.1, y: 8.9), control2: CGPoint(x: 2.3, y: 8.5))
                context.addCurve(
                    to: CGPoint(x: 5.0, y: 5.2), control1: CGPoint(x: 2.3, y: 6.4), control2: CGPoint(x: 3.5, y: 5.2))
                context.closePath()
            }
            paint(fill: "#F6EADD", stroke: "#B08A5E") {
                for (cx, cy, rx, ry) in [
                    (1.9, 4.6, 0.95, 1.2), (4.0, 2.9, 1.0, 1.3), (6.0, 2.9, 1.0, 1.3), (8.1, 4.6, 0.95, 1.2),
                ] {
                    context.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
                }
            }
        case .leaf:
            paint(fill: "#E4F0DC", stroke: "#7FA65B") {
                context.move(to: CGPoint(x: 1.0, y: 8.6))
                context.addCurve(
                    to: CGPoint(x: 9.0, y: 1.4), control1: CGPoint(x: 1.4, y: 4.4), control2: CGPoint(x: 4.6, y: 1.6))
                context.addCurve(
                    to: CGPoint(x: 1.0, y: 8.6), control1: CGPoint(x: 8.8, y: 5.6), control2: CGPoint(x: 5.6, y: 8.6))
                context.closePath()
                context.move(to: CGPoint(x: 1.0, y: 8.6))
                context.addCurve(
                    to: CGPoint(x: 7.0, y: 3.2), control1: CGPoint(x: 3.0, y: 6.4), control2: CGPoint(x: 5.0, y: 4.6))
            }
        case .bow:
            paint(fill: "#FBE1E6", stroke: "#D9738A") {
                context.move(to: CGPoint(x: 5.0, y: 4.6))
                context.addCurve(
                    to: CGPoint(x: 0.8, y: 2.8), control1: CGPoint(x: 3.6, y: 3.0), control2: CGPoint(x: 1.6, y: 2.2))
                context.addCurve(
                    to: CGPoint(x: 0.8, y: 6.4), control1: CGPoint(x: 0.1, y: 3.4), control2: CGPoint(x: 0.1, y: 5.8))
                context.addCurve(
                    to: CGPoint(x: 5.0, y: 4.6), control1: CGPoint(x: 1.6, y: 7.0), control2: CGPoint(x: 3.6, y: 6.2))
                context.closePath()
                context.move(to: CGPoint(x: 5.0, y: 4.6))
                context.addCurve(
                    to: CGPoint(x: 9.2, y: 2.8), control1: CGPoint(x: 6.4, y: 3.0), control2: CGPoint(x: 8.4, y: 2.2))
                context.addCurve(
                    to: CGPoint(x: 9.2, y: 6.4), control1: CGPoint(x: 9.9, y: 3.4), control2: CGPoint(x: 9.9, y: 5.8))
                context.addCurve(
                    to: CGPoint(x: 5.0, y: 4.6), control1: CGPoint(x: 8.4, y: 7.0), control2: CGPoint(x: 6.4, y: 6.2))
                context.closePath()
            }
            paint(fill: "#FBE1E6", stroke: "#D9738A") {
                context.move(to: CGPoint(x: 4.5, y: 5.4))
                context.addCurve(
                    to: CGPoint(x: 2.5, y: 9.2), control1: CGPoint(x: 4.1, y: 6.8), control2: CGPoint(x: 3.3, y: 8.2))
                context.addLine(to: CGPoint(x: 3.8, y: 8.9))
                context.addLine(to: CGPoint(x: 4.3, y: 9.8))
                context.addCurve(
                    to: CGPoint(x: 5.0, y: 5.5), control1: CGPoint(x: 5.0, y: 8.3), control2: CGPoint(x: 5.1, y: 6.9))
                context.closePath()
                context.move(to: CGPoint(x: 5.5, y: 5.4))
                context.addCurve(
                    to: CGPoint(x: 7.5, y: 9.2), control1: CGPoint(x: 5.9, y: 6.8), control2: CGPoint(x: 6.7, y: 8.2))
                context.addLine(to: CGPoint(x: 6.2, y: 8.9))
                context.addLine(to: CGPoint(x: 5.7, y: 9.8))
                context.addCurve(
                    to: CGPoint(x: 5.0, y: 5.5), control1: CGPoint(x: 5.0, y: 8.3), control2: CGPoint(x: 4.9, y: 6.9))
                context.closePath()
            }
            paint(fill: "#F6C7D2", stroke: "#D9738A") {
                context.addPath(
                    CGPath(
                        roundedRect: CGRect(x: 4.2, y: 3.9, width: 1.6, height: 1.5), cornerWidth: 0.5,
                        cornerHeight: 0.5, transform: nil))
            }
        case .star, .filledStar:
            paint(fill: motif == .star ? "#F3F0FB" : "#D9D2F0", stroke: "#8F80C4") {
                for index in 0..<10 {
                    let radius = index.isMultiple(of: 2) ? 4.6 : 2.05
                    let angle = -.pi / 2 + Double(index) * .pi / 5
                    let point = CGPoint(x: 5 + cos(angle) * radius, y: 5 + sin(angle) * radius)
                    if index == 0 { context.move(to: point) } else { context.addLine(to: point) }
                }
                context.closePath()
            }
        case .moon:
            paint(fill: "#FBF3D2", stroke: "#C9A64E") {
                context.move(to: CGPoint(x: 6.6, y: 0.9))
                context.addCurve(
                    to: CGPoint(x: 9.3, y: 7.6), control1: CGPoint(x: -2, y: -1.5), control2: CGPoint(x: 0, y: 14))
                context.addCurve(
                    to: CGPoint(x: 6.6, y: 0.9), control1: CGPoint(x: 3.8, y: 8.2), control2: CGPoint(x: 3.4, y: 3))
                context.closePath()
            }
        case .flower, .purpleFlower:
            paint(fill: motif == .flower ? "#FBE7EC" : "#EEE9F8", stroke: motif == .flower ? "#E08FA6" : "#A99BD1") {
                for index in 0..<5 {
                    let angle = -.pi / 2 + Double(index) * 2 * .pi / 5
                    context.addEllipse(
                        in: CGRect(
                            x: 5 + cos(angle) * 2.2 - 1.9, y: 5 + sin(angle) * 2.2 - 1.9, width: 3.8, height: 3.8))
                }
            }
            paint(fill: "#FBEFC4", stroke: "#D9A63E") {
                context.addEllipse(in: CGRect(x: 3.75, y: 3.75, width: 2.5, height: 2.5))
            }
        }
    }

    private func paint(fill: String?, stroke: String, path: () -> Void) {
        context.setStrokeColor(Self.color(stroke) ?? CGColor(gray: 0.5, alpha: 1))
        if let fill { context.setFillColor(Self.color(fill) ?? CGColor(gray: 1, alpha: 1)) }
        context.beginPath()
        path()
        context.drawPath(using: fill == nil ? .stroke : .fillStroke)
    }
}
