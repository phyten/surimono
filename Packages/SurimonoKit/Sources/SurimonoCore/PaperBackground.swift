import CoreGraphics
import Foundation

/// The paper of a print theme: the background its style sheet gives the root element, which covers the whole page.
///
/// WebKit paints that background only inside the page's margins, so a tinted or ruled paper came out framed in
/// white. The text pages are therefore laid out without it, and a page of its own draws it over the whole sheet,
/// under the text. Its root's content box sits where the text area is, so a pattern keeps lining up with the text
/// and the margins only show more of the same paper. A body background stays with the text area; a theme with paper
/// keeps its body clear or of the same color.
public enum PaperBackground {
    /// The id of the style element that keeps the text pages free of paper. It is in the document from the start:
    /// a paper first drawn and then taken away by a script was still printed in part.
    public static let removalStyleID = "surimono-paper"

    /// The style element that keeps the paper off the text pages.
    public static let removalStyle =
        "<style id=\"\(removalStyleID)\">html { background: none !important; }</style>"

    /// A preparation script for the text pages that returns "paper" when the theme gives the root a background; plain
    /// white counts as none. It looks with the removal style turned off for a moment, before anything is drawn.
    ///
    /// Printing shrinks a page that is wider than its paper further than others, which a paper laid under it would not
    /// follow. Such a page keeps its paper and returns nothing, so WebKit draws the paper inside the margins only.
    public static let detectionScript = """
        {
          const removal = document.getElementById('\(removalStyleID)');
          if (removal) removal.disabled = true;
          const root = document.documentElement;
          const style = getComputedStyle(root);
          const color = style.backgroundColor;
          const tinted = color !== 'rgba(0, 0, 0, 0)' && color !== 'rgb(255, 255, 255)';
          const paper = style.backgroundImage !== 'none' || tinted;
          const separate = paper && root.scrollWidth <= root.clientWidth + 1;
          if (removal) removal.disabled = !separate;
          return separate ? 'paper' : '';
        }
        """

    /// A preparation script for the paper page. A paper drawn only with images over a transparent color can print
    /// black where the images leave it clear, so it gets the white of a sheet underneath.
    public static let opaqueScript = """
        {
          const root = document.documentElement;
          if (getComputedStyle(root).backgroundColor === 'rgba(0, 0, 0, 0)') {
            root.style.setProperty('background-color', '#fff', 'important');
          }
        }
        """

    /// The document that draws only the paper of `theme` on one logical page laid out without margins.
    /// - Parameters:
    ///   - pageSize: The logical page, in points.
    ///   - marginInMillimeters: The margin the text pages are laid out with.
    ///   - pixelsPerPoint: CSS pixels to a point of the page, as the text pages are drawn. WebKit lays a printed page
    ///     out wider than its paper and shrinks it to fit; a capture at the screen's scale draws a pixel to a point.
    public static func document(
        theme: PrintTheme, format: DocumentFormat, baseURL: URL? = nil, language: String = "ja", textScale: Double = 1,
        pageSize: CGSize, marginInMillimeters: Double, pixelsPerPoint: Double
    ) -> String {
        let base = baseURL.map { "<base href=\"\(HTML.escape($0.absoluteString))\">\n" } ?? ""
        let css = styleSheet(
            theme: theme, textScale: textScale, pageSize: pageSize, marginInMillimeters: marginInMillimeters,
            pixelsPerPoint: pixelsPerPoint)
        return """
            <!doctype html>
            <html lang="\(HTML.escape(language))">
            <head>
            <meta charset="utf-8">
            \(base)<style>
            \(css)
            </style>
            </head>
            <body class="surimono format-\(format.rawValue)"></body>
            </html>
            """
    }

    /// The paper page's one style element: the theme's style sheet, then the root's content box placed over the text
    /// area. The images start from that box: WebKit places a root's images that do not repeat without its margins.
    public static func styleSheet(
        theme: PrintTheme, textScale: Double = 1, pageSize: CGSize, marginInMillimeters: Double, pixelsPerPoint: Double
    ) -> String {
        // The text pages scale the root with zoom, its own box included, so its place is given unscaled.
        let zoom = textScale.isFinite && textScale > 0 ? textScale : 1
        let ratio = pixelsPerPoint.isFinite && pixelsPerPoint > 0 ? pixelsPerPoint : 1
        let margin = max(marginInMillimeters.isFinite ? marginInMillimeters : 0, 0) * 72 / 25.4
        let height = max(Double(pageSize.height) - 2 * margin, 0)
        return HTMLDocumentBuilder.styleSheet(theme: theme, textScale: textScale) + """

            html { margin: 0 !important; padding: \(margin * ratio / zoom)px !important; border: 0 !important; \
            height: \(height * ratio / zoom)px !important; min-height: 0 !important; \
            box-sizing: content-box !important; background-origin: content-box !important; }
            body { margin: 0 !important; padding: 0 !important; border: 0 !important; height: 0 !important; \
            min-height: 0 !important; overflow: hidden !important; }
            """
    }
}
