import AppKit
import CoreText
import SurimonoCore
import SurimonoFormats

/// Shared by imposed sheets and the view-only PDF copies. Coordinates are page points, bottom-up.
@MainActor
public enum PageNumberDrawing {
    public static func draw(
        _ number: Int, in rect: CGRect, margin: CGFloat, scale: CGFloat = 1, context: CGContext
    ) {
        let text = NSAttributedString(
            string: String(number),
            attributes: [.font: NSFont.systemFont(ofSize: 8 * scale), .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(text)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.textMatrix = .identity
        // With zero margins, keep the label inside the page instead of clipping it below the media box.
        let centerY = rect.minY + max(margin / 2, (ascent + descent) / 2 + 2)
        context.textPosition = CGPoint(x: rect.midX - width / 2, y: centerY - (ascent - descent) / 2)
        CTLineDraw(line, context)
    }
}

/// The header and footer of a page, in the same type as the plain page number.
enum PageFurnitureDrawing {
    private static let elementFaces = Dictionary(
        uniqueKeysWithValues: ComputerModernFamily.allCases.flatMap { family in
            family.faces.compactMap { file, weight, shape in
                ComputerModernFamily.data(for: file).map { (family.rawValue + weight + shape, $0) }
            }
        })

    private static func footerFont(_ style: PageFurniture.LaTeXFooter, scale: CGFloat) -> NSFont {
        let size = style.pointSize * scale
        if let name = style.fontName, let font = InstalledFontIndex.systemFont(named: name, size: size) as NSFont? {
            return font
        }
        if let computerModern = elementFaces[ComputerModernFamily.roman.rawValue + "normalnormal"],
            let provider = CGDataProvider(data: computerModern as CFData),
            let font = CGFont(provider)
        {
            return CTFontCreateWithGraphicsFont(font, size, nil, nil) as NSFont
        }
        return InstalledFontIndex.systemFont(named: "Times New Roman", size: size) as NSFont?
            ?? NSFont.systemFont(ofSize: size)
    }

    private static func elementFont(_ element: LaTeXElementFont?, style: PageFurniture.LaTeXFooter, scale: CGFloat)
        -> NSFont
    {
        guard var element else { return footerFont(style, scale: scale) }
        if element.shape == "oblique", element.family != "mono", element.family != "sans",
            let name = style.fontName, InstalledFontIndex.system.face(named: name) != nil
        {
            // Keep the existing slant for an explicitly selected installed text face.
            element.shape = "normal"
            let upright = elementFont(element, style: style, scale: scale)
            var slant = CGAffineTransform(a: 1, b: 0, c: 1 / 6, d: 1, tx: 0, ty: 0)
            return CTFontCreateCopyWithAttributes(upright, 0, &slant, nil) as NSFont
        }
        let base = style.classSize == 11 ? 10.95 : Double(style.classSize)
        let size = style.pointSize * scale * ((element.pointSize(base: style.classSize) ?? base) / base)
        if let family = element.family, !["mono", "sans", "roman"].contains(family),
            let font = InstalledFontIndex.systemFont(named: family, size: size)
        {
            return font as NSFont
        }
        if element.family != "sans", element.family != "mono", let installed = style.fontName,
            let face = InstalledFontIndex.system.face(named: installed)
        {
            let family = InstalledFontIndex.system.face(named: face.family) ?? face
            let variant: String? =
                switch (element.weight == "bold", element.shape == "italic") {
                case (true, true): family.boldItalic
                case (true, false): family.bold
                case (false, true): family.italic
                case (false, false): family.postScriptName
                }
            if let font = NSFont(name: variant ?? face.postScriptName, size: size) { return font }
        }
        let family: ComputerModernFamily =
            element.family == "mono" ? .typewriter : element.family == "sans" ? .sans : .roman
        if family == .roman, element.capitals == "small-caps",
            let smallCaps = NSFont(
                name: element.weight == "bold" ? "IowanOldStyle-Bold" : "IowanOldStyle-Roman", size: size)
        {
            // Use the same searchable small-cap glyphs as WebKit's print style.
            let features = CTFontDescriptorCreateCopyWithFeature(
                CTFontCopyFontDescriptor(smallCaps), kLowerCaseType as CFNumber, kLowerCaseSmallCapsSelector as CFNumber
            )
            return CTFontCreateCopyWithAttributes(smallCaps, size, nil, features) as NSFont
        }
        return bundledFont(family, weight: element.weight, shape: element.shape, size: size)
            ?? footerFont(style, scale: scale)
    }

    private static func bundledFont(_ family: ComputerModernFamily, weight: String?, shape: String?, size: CGFloat)
        -> NSFont?
    {
        let key = family.rawValue + (weight ?? "normal")
        let shape = shape ?? "normal"
        // Sans uses oblique for italic; the bold typewriter uses italic for oblique.
        let data = elementFaces[key + shape] ?? elementFaces[key + (shape == "italic" ? "oblique" : "italic")]
        if let data, let provider = CGDataProvider(data: data as CFData), let face = CGFont(provider) {
            return CTFontCreateWithGraphicsFont(face, size, nil, nil) as NSFont
        }
        return nil
    }

    private struct Row {
        let lines: [CTLine?]
        let height: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// Draws above and below the text area; `margins` are in the units of `rect`.
    static func draw(
        _ lines: PageFurniture.Lines, in rect: CGRect, margins: WebPaginator.Margins, scale: CGFloat,
        latexFooter: PageFurniture.LaTeXFooter? = nil, asOutlines: Bool = false, context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.textMatrix = .identity
        // With no margin, the text stays inside the page instead of being cut off by its edge.
        let inset = 2 * scale
        let outer = min(margins.left, margins.right)
        let left = rect.minX + max(lines.spansOuterMargin ? outer : margins.left, inset)
        let right = rect.maxX - max(lines.spansOuterMargin ? outer : margins.right, inset)
        let center = rect.minX + margins.left + (rect.width - margins.left - margins.right) / 2
        func draw(_ texts: [String], above: Bool, centerY: (CGFloat) -> CGFloat) {
            let rule = (above ? lines.headRule : lines.footRule) * scale
            guard rule > 0 || texts.contains(where: { !$0.isEmpty }) else { return }
            let journal = lines.journalPage
            let headFamily = (lines.headerFont ?? latexFooter?.headerFont)?.family
            let usesJapaneseFace = above && headFamily != "mono" && headFamily != "sans"
            let rowLeft = left + (above ? journal?.headerLeftInset ?? 0 : journal?.footerSideInset ?? 0) * scale
            let rowRight = right - (above ? 0 : journal?.footerSideInset ?? 0) * scale
            let japaneseFace = above ? journal?.japaneseHeaderFace : journal?.japaneseFooterFace
            let japaneseScale = above ? journal?.japaneseHeaderScale : journal?.japaneseFooterScale
            let row = row(
                texts, width: rowRight - rowLeft, scale: scale,
                font: latexFooter.map {
                    elementFont(
                        above ? (lines.headerFont ?? $0.headerFont) : journal?.footerFont, style: $0, scale: scale)
                },
                numberFont: latexFooter.flatMap { style in
                    (lines.numberFont ?? style.numberFont).map { elementFont($0, style: style, scale: scale) }
                },
                ranges: above ? lines.headerNumberRanges : lines.footerNumberRanges,
                oversizedTitleFallback: above ? lines.oversizedTitleFallback : nil,
                japaneseFamily: japaneseFace ?? (usesJapaneseFace ? latexFooter?.japaneseFontName : nil),
                japaneseScale: japaneseScale ?? latexFooter?.japaneseFontScale ?? 1,
                copyrightFont: above
                    ? nil
                    : latexFooter.flatMap { style in
                        journal?.copyrightFont.map { elementFont($0, style: style, scale: scale) }
                    }, fitsOppositeField: journal != nil)
            let y =
                latexFooter.map {
                    let strut = above && lines.usesFancyFields ? $0.headerStrutDepth : 0
                    let baseline =
                        above
                        ? rect.height - margins.top + ($0.headSep + strut) * scale
                        : margins.bottom - $0.footSkip * scale
                    return rect.minY + min(rect.height - row.ascent, max(row.descent, baseline))
                } ?? (centerY(row.height) - (row.ascent - row.descent) / 2)
            if rule > 0 {
                let footGap = (latexFooter?.pointSize ?? 10) * 0.36 * scale
                let ruleDepth = journal?.headRuleDepth ?? (lines.usesFancyFields ? latexFooter?.headerRuleDepth : nil)
                let headDepth = ruleDepth.map { $0 * scale } ?? row.descent
                let edge = above ? y - headDepth - rule : y + row.ascent + footGap
                if journal?.interruptsRuleAtLeftText == true, above, let title = row.lines[0] {
                    let endOfTitle = rowLeft + CTLineGetTypographicBounds(title, nil, nil, nil)
                    drawRule(from: left, to: rowLeft, center: edge + rule / 2, thickness: rule, context: context)
                    drawRule(from: endOfTitle, to: right, center: edge + rule / 2, thickness: rule, context: context)
                } else {
                    drawRule(from: left, to: right, center: edge + rule / 2, thickness: rule, context: context)
                }
            }
            for (index, line) in row.lines.enumerated() {
                guard let line else { continue }
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                let x = index == 0 ? rowLeft : index == 1 ? center - width / 2 : rowRight - width
                let lowering = above ? journal?.headerLowering[index] : journal?.footerLowering
                context.textPosition = CGPoint(x: x, y: y - (lowering ?? 0) * scale)
                show(line, asOutlines: asOutlines, context: context)
            }
            if let extra = journal?.secondary, extra.header == above, let latexFooter {
                let font = elementFont(extra.font, style: latexFooter, scale: scale)
                let slot = extra.trailingInset == nil ? 0 : 2
                var parts = ["", "", ""]
                parts[slot] = extra.text
                let extraLine = Self.row(parts, width: right - left, scale: scale, font: font)
                if let line = extraLine.lines[slot] {
                    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                    let x = extra.trailingInset.map { right - $0 * scale - width } ?? left
                    context.textPosition = CGPoint(x: x, y: y - extra.loweredMM * 72 / 25.4 * scale)
                    show(line, asOutlines: asOutlines, context: context)
                }
            }
        }
        draw(lines.top, above: true) { rect.maxY - max(margins.top / 2, $0 / 2 + 2) }
        draw(lines.bottom, above: false) { rect.minY + max(margins.bottom / 2, $0 / 2 + 2) }
    }

    /// One line of the handout's page: the text of the three places around its slot, in `space` above or below it.
    static func drawHandoutRow(
        _ texts: [String], beside rect: CGRect, above: Bool, space: CGFloat, padding: CGFloat, rule: CGFloat,
        context: CGContext
    ) {
        let row = row(texts, width: rect.width, scale: 1)
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        let fits = space >= row.height + 2 * padding
        if !fits && above { return }
        if rule > 0 {
            // The handout puts furniture around the slot using sheet coordinates.
            let edge = above ? rect.maxY : rect.minY - min(space, rule)
            drawRule(from: rect.minX, to: rect.maxX, center: edge + rule / 2, thickness: rule, context: context)
        }
        for (index, line) in row.lines.enumerated() {
            guard let line else { continue }
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let x = index == 0 ? rect.minX : index == 1 ? rect.midX - width / 2 : rect.maxX - width
            if fits {
                let center = above ? rect.maxY + space / 2 : rect.minY - space / 2
                context.textPosition = CGPoint(x: x, y: center - (row.ascent - row.descent) / 2)
            } else {
                // The last slot has no usable footer with zero or tiny margins; white backing preserves contrast.
                let start = index == 1 ? rect.minX : x
                let backing = CGRect(
                    x: start, y: rect.minY, width: width + 2 * padding, height: row.height + 2 * padding)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(backing)
                context.textPosition = CGPoint(x: backing.minX + padding, y: backing.minY + padding + row.descent)
            }
            CTLineDraw(line, context)
        }
    }

    private static func drawRule(
        from left: CGFloat, to right: CGFloat, center: CGFloat, thickness: CGFloat, context: CGContext
    ) {
        guard right > left else { return }
        // PDF viewers can enhance subpixel strokes at reading zoom. pdfTeX also emits a
        // butt-capped stroke for this rule so its endpoints and physical width survive scaling.
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(1)
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(thickness)
        context.setLineCap(.butt)
        context.setLineDash(phase: 0, lengths: [])
        context.beginPath()
        context.move(to: CGPoint(x: left, y: center))
        context.addLine(to: CGPoint(x: right, y: center))
        context.strokePath()
    }

    /// Draws a line at the context's text position, as text or as the shapes of its letters. The view mode's paper
    /// keeps the text of its page alone, for selecting, copying and finding it; the sheets keep real text.
    static func show(_ line: CTLine, asOutlines: Bool, context: CGContext) {
        guard asOutlines else { return CTLineDraw(line, context) }
        let origin = context.textPosition
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
            // Each run has its own font, also where a letter came from a fallback font, and its own color.
            guard count > 0, let font = attributes[.font] as? NSFont else { continue }
            let color = (attributes[.foregroundColor] as? NSColor)?.cgColor ?? CGColor(gray: 0, alpha: 1)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            let path = CGMutablePath()
            for (glyph, position) in zip(glyphs, positions) {
                let place = CGPoint(x: origin.x + position.x, y: origin.y + position.y)
                if let outline = CTFontCreatePathForGlyph(font, glyph, nil) {
                    path.addPath(outline, transform: CGAffineTransform(translationX: place.x, y: place.y))
                } else {
                    // A color glyph such as an emoji has no outline; it is drawn as the picture it is.
                    drawPicture(of: glyph, font: font, at: place, context: context)
                }
            }
            context.saveGState()
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
    }

    /// How much finer than the page a glyph's picture is, so that it stays sharp at the paper's largest zoom.
    static let pictureScale: CGFloat = 8

    private static func drawPicture(of glyph: CGGlyph, font: NSFont, at place: CGPoint, context: CGContext) {
        var glyph = glyph
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1).integral
        guard !bounds.isEmpty, bounds.width.isFinite, bounds.height.isFinite,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let bitmap = CGContext(
                data: nil, width: Int(bounds.width * pictureScale), height: Int(bounds.height * pictureScale),
                bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        bitmap.scaleBy(x: pictureScale, y: pictureScale)
        var origin = CGPoint(x: -bounds.minX, y: -bounds.minY)
        CTFontDrawGlyphs(font, &glyph, &origin, 1, bitmap)
        guard let image = bitmap.makeImage() else { return }
        context.draw(image, in: bounds.offsetBy(dx: place.x, dy: place.y))
    }

    /// The lines of a row, each kept to its share of `width` so that long names do not run into each other.
    private static func row(
        _ texts: [String], width: CGFloat, scale: CGFloat, font: NSFont? = nil, numberFont: NSFont? = nil,
        ranges: [[NSRange]] = [], oversizedTitleFallback: String? = nil, japaneseFamily: String? = nil,
        japaneseScale: Double = 1, copyrightFont: NSFont? = nil, fitsOppositeField: Bool = false
    ) -> Row {
        let font = font ?? NSFont.systemFont(ofSize: 8 * scale)
        // Match the print stylesheet: only substituted letters need the searchable small-cap face.
        let features = CTFontCopyFeatureSettings(font) as? [[String: Int]]
        let usesSmallCaps =
            features?.contains {
                $0[kCTFontFeatureTypeIdentifierKey as String] == kLowerCaseType
                    && $0[kCTFontFeatureSelectorIdentifierKey as String] == kLowerCaseSmallCapsSelector
            } == true
        let isBold = font.fontName == "IowanOldStyle-Bold"
        let capitals =
            usesSmallCaps && (isBold || font.fontName == "IowanOldStyle-Roman")
            ? bundledFont(.roman, weight: isBold ? "bold" : nil, shape: nil, size: font.pointSize) : nil
        let letterFont =
            capitals != nil && !isBold
            ? CTFontCreateCopyWithAttributes(font, font.pointSize * ThemeFonts.smallCapScale, nil, nil) as NSFont : font
        func line(_ text: String, slot: Int? = nil) -> CTLine {
            let contents = NSMutableAttributedString(
                string: text, attributes: [.font: letterFont, .foregroundColor: NSColor.black])
            if let capitals {
                for range in text.ranges(of: /[^\p{Ll}\p{M}]+/) {
                    contents.addAttribute(.font, value: capitals, range: NSRange(range, in: text))
                }
            }
            if font.fontName.hasPrefix("CMU") {
                contents.addAttribute(.ligature, value: 0, range: NSRange(location: 0, length: contents.length))
            }
            if let japaneseFamily,
                let face = InstalledFontIndex.systemFont(named: japaneseFamily, size: font.pointSize * japaneseScale)
                    ?? InstalledFontIndex.systemFont(named: "HiraMinProN-W3", size: font.pointSize * japaneseScale)
            {
                // The class's JFM scales Japanese glyphs independently of Latin digits.
                for range in text.ranges(of: /[\p{Han}\p{Hiragana}\p{Katakana}\u{3000}-\u{303F}\u{FF01}-\u{FF60}]+/) {
                    contents.addAttribute(.font, value: face, range: NSRange(range, in: text))
                }
            }
            if let copyrightFont, let range = text.range(of: "©") {
                contents.addAttribute(.font, value: copyrightFont, range: NSRange(range, in: text))
            }
            if let slot, let numberFont, ranges.indices.contains(slot) {
                for range in ranges[slot] where NSMaxRange(range) <= contents.length {
                    contents.addAttribute(.font, value: numberFont, range: range)
                }
            }
            return CTLineCreateWithAttributedString(contents)
        }
        var lines = texts.enumerated().map { line($0.element, slot: $0.offset) }
        if let oversizedTitleFallback {
            // The kit checks the height above the baseline of the actual 9pt title box.
            // Font ascent would reject even an ordinary line with no tall accents.
            let middle = lines[1]
            if CTLineGetTypographicBounds(middle, nil, nil, nil) > width
                || CTLineGetBoundsWithOptions(middle, .useGlyphPathBounds).maxY > font.pointSize * (6.25 / 9)
            {
                lines[1] = line(oversizedTitleFallback)
            }
        }
        let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        func fitted(_ index: Int, to limit: CGFloat) -> CTLine? {
            guard !texts[index].isEmpty, limit > 0 else { return nil }
            guard widths[index] > limit else { return lines[index] }
            return CTLineCreateTruncatedLine(lines[index], limit, .end, line("…"))
        }
        let gap = 8 * scale
        let middle = fitted(
            1, to: PageFurniture.centerLimit(left: widths[0], right: widths[2], available: width, gap: gap))
        let middleWidth = middle.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) } ?? 0
        let bothSides = !texts[0].isEmpty && !texts[2].isEmpty
        let side = middle != nil ? (width - middleWidth) / 2 - gap : bothSides ? (width - gap) / 2 : width
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line("0"), &ascent, &descent, nil)
        if let numberFont, ranges.contains(where: { !$0.isEmpty }) {
            ascent = max(ascent, numberFont.ascender)
            descent = max(descent, -numberFont.descender)
        }
        // A journal header shares a row with just the folio: let its title use the folio's unused half.
        func available(opposite: Int) -> CGFloat {
            guard fitsOppositeField, middle == nil, bothSides else { return side }
            return width - gap - min(width / 2, widths[opposite])
        }
        return Row(
            lines: [fitted(0, to: available(opposite: 2)), middle, fitted(2, to: available(opposite: 0))],
            height: ascent + descent,
            ascent: ascent, descent: descent)
    }
}
