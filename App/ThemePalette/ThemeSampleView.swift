import PDFKit
import SurimonoRendering
import SwiftUI

/// A sample page on white paper: the sampled printable area drawn as vectors inside the paper's margins, so it stays
/// sharp at any size. Until the sample is drawn, the paper shows a few faint lines in its place.
struct ThemeSampleView: View {
    let page: PDFPage?
    let paperSize: CGSize
    let margins: WebPaginator.Margins
    var cornerRadius: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            let scale = size.width / max(paperSize.width, 1)
            let content = CGRect(
                x: margins.left * scale, y: margins.top * scale,
                width: (paperSize.width - margins.left - margins.right) * scale,
                height: (paperSize.height - margins.top - margins.bottom) * scale)
            guard let page else {
                placeholder(in: content, context: context)
                return
            }
            let bounds = page.bounds(for: .mediaBox)
            let pageScale = content.width / max(bounds.width, 1)
            context.withCGContext { cg in
                cg.saveGState()
                cg.clip(to: content)
                // PDF pages draw upward from the bottom left; the canvas runs downward from the top left.
                cg.translateBy(x: content.minX, y: content.minY + bounds.height * pageScale)
                cg.scaleBy(x: pageScale, y: -pageScale)
                cg.translateBy(x: -bounds.minX, y: -bounds.minY)
                page.draw(with: .mediaBox, to: cg)
                cg.restoreGState()
            }
        }
        .aspectRatio(paperSize.width / max(paperSize.height, 1), contentMode: .fit)
        // The paper is white in both appearances, like the printed sheet.
        .background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.white))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    private func placeholder(in content: CGRect, context: GraphicsContext) {
        let line = Color.black.opacity(0.07)
        let lineHeight = max(content.height / 26, 1.5)
        for index in 0..<8 {
            let width = content.width * (index == 0 ? 0.55 : index % 3 == 2 ? 0.7 : 0.95)
            let rect = CGRect(
                x: content.minX, y: content.minY + CGFloat(index) * lineHeight * 2.2, width: width, height: lineHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: lineHeight / 2), with: .color(line))
        }
    }
}
