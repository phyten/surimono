import AppKit
import PDFKit
import Testing

// Called from the timed print test to inspect the same physical pages that the reader exports.
@MainActor
func compareBeamerReference(_ pdf: PDFDocument, to reference: PDFDocument, fixture: String) throws {
    let anchors: [(Int, [String])]
    switch fixture {
    case "083":
        anchors = [
            (0, ["A folded rail spacer", "Model Rail Desk", "Paper Model Workshop", "14 May 2026"]),
            (1, ["A fixed rail height", "Observation", "The folded card", "The folded edge"]),
            (2, ["Readings", "Thin", "Folded", "Spacer heights", "Model Rail Desk"]),
        ]
    case "specimen":
        anchors = [
            (0, ["A pocket tide gauge", "Field notes", "Mira Reed", "Harbour Workshop", "22 May"]),
            (1, ["Assembly"]),
            (
                2,
                [
                    "Cut the scale", "A dry bench", "Mark the", "Yard stick", "Copper sleeve", "Inner pin", "File",
                    "Tip", "Use a flat edge",
                ]
            ),
            (3, ["Calibrate", "Reading", "Turn the brass", "Caution", "Keep the scale", "Example", "Seven marks"]),
            (4, ["North gauge", "High water", "South gauge", "The tide turns", "Logged at noon"]),
            (8, ["Harbour Crew"]),
            (5, ["Tag", "mark<2->"]),
            (6, ["Records"]),
            (7, ["Section", "Records"]),
            (9, ["Bench record", "The copper gauge", "Mark", "Depth", "The morning reading"]),
        ]
    case "additive":
        anchors = [
            (0, ["Record the tide", "Start at the wet mark", "Read the ruler", "Enter the depth", "Close the ledger"])
        ]
    case "handout":
        anchors = [(0, ["Notebook", "Record the level", "Read the float", "Mark the page"])]
    case "swap":
        // The reference requests Madrid. The default-theme slide still has to preserve each
        // step's text and its reading order, including space reserved by a covered paragraph.
        for (i, lines) in [["Low water"], ["High water", "shows the next mark"]].enumerated() {
            try checkBeamerReadingOrder(in: #require(pdf.page(at: i)), words: lines)
            try checkBeamerReadingOrder(in: #require(reference.page(at: i)), words: lines)
        }
        return
    default: return
    }
    for (index, words) in anchors {
        let page = try #require(pdf.page(at: index))
        let tex = try #require(reference.page(at: index))
        if fixture == "specimen", index == 4 {
            // PDFKit may infer a column order from geometry even when both PDF streams paint the
            // columns first. Compare the two documents with the same version of that extractor.
            let text = try #require(tex.string)
            let offsets = try words.map { word in (word, try #require(text.range(of: word)).lowerBound) }
            try checkBeamerReadingOrder(in: page, words: offsets.sorted { $0.1 < $1.1 }.map(\.0))
        } else {
            try checkBeamerReadingOrder(in: page, words: words)
        }
        for word in words {
            let actual = try printedInk(of: word, in: pdf, on: page)
            let expected = try printedInk(of: word, in: reference, on: tex)
            // TeX uses an optical 8-point sans face for the institute. The slide uses the same
            // size and centring with the bundled design, whose natural advances are narrower.
            let isInstitute = ["Harbour Workshop", "Paper Model Workshop"].contains(word)
            let x = isInstitute ? actual.midX - expected.midX : actual.minX - expected.minX
            #expect(abs(x) <= (isInstitute ? 1 : 2), "\(fixture) \(index + 1) \(word) 左端")
            func verticalPosition() -> String {
                func face(in deck: PDFDocument, on sheet: PDFPage) -> String {
                    guard let hit = deck.findString(word).first(where: { $0.pages.contains(sheet) })?.attributedString,
                        hit.length > 0, let font = hit.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
                    else { return "?" }
                    return "\(font.fontName)@\(font.pointSize)"
                }
                return
                    "\(fixture) p\(index + 1) \(word) inkY=\(actual.minY) TeX=\(expected.minY) Δ=\(actual.minY - expected.minY)pt (±2pt) "
                    + "font=\(face(in: pdf, on: page))/\(face(in: reference, on: tex)) scale=\(NSScreen.main?.backingScaleFactor ?? 0)"
            }
            #expect(abs(actual.minY - expected.minY) <= 2, "\(verticalPosition())")
        }
    }
    if fixture == "specimen" || fixture == "083" {
        let index = fixture == "specimen" ? 8 : 2
        let top = fixture == "specimen" ? 117 : 167
        func paperIcon(in deck: PDFDocument) throws -> CGRect {
            let pixels = try PagePixels(#require(deck.page(at: index)))
            var bounds = CGRect.null
            var cream = 0
            var illustration = 0
            for row in top * 4..<(top + 18) * 4 {
                for col in 28 * 4..<44 * 4 {
                    let point = CGPoint(x: CGFloat(col) / 4, y: CGFloat(row) / 4)
                    let (r, g, b) = pixels.color(atX: point.x, y: point.y)
                    if min(r, g, b) < 225 {
                        bounds = bounds.union(CGRect(origin: point, size: CGSize(width: 0.25, height: 0.25)))
                    }
                    if abs(r - g) < 6 && r > 165 && b + 10 < g { cream += 1 }
                    if max(r, g, b) - min(r, g, b) > 30 && min(r, g, b) < 125 { illustration += 1 }
                }
            }
            #expect(cream > 20 && illustration > 5, "紙色と小さな挿絵が刷られる")
            return bounds
        }
        let actual = try paperIcon(in: pdf)
        let expected = try paperIcon(in: reference)
        #expect(abs(actual.minX - expected.minX) <= 1 && abs(actual.maxX - expected.maxX) <= 1)
        #expect(
            abs(actual.minY - expected.minY) <= 1 && abs(actual.maxY - expected.maxY) <= 1,
            "\(fixture) p\(index + 1) icon=\(actual) TeX=\(expected)")
    }
    if fixture == "083" {
        try checkSlideRules(in: pdf, against: reference, page: 1, top: 130, bottom: 146, x: 180)
        try checkBlockGap(in: pdf, against: reference, page: 1, title: "Observation", body: "The folded card")
    }
    guard fixture == "specimen" else { return }
    try checkSlideRules(in: pdf, against: reference, page: 0, top: 197, bottom: 214, x: 180)
    try checkSlideRules(in: pdf, against: reference, page: 4, top: 254, bottom: 261, x: 130)
    for (title, body) in [("Reading", "Turn the brass"), ("Caution", "Keep the scale"), ("Example", "Seven marks")] {
        try checkBlockGap(in: pdf, against: reference, page: 3, title: title, body: body)
    }
    func noteMarks(in deck: PDFDocument) throws -> [CGFloat] {
        let page = try #require(deck.page(at: 4))
        return try deck.findString("1").filter { $0.pages.contains(page) }.map { selection in
            let text = try #require(selection.attributedString)
            return try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize
        }.sorted()
    }
    let actualMarks = try noteMarks(in: pdf)
    let referenceMarks = try noteMarks(in: reference)
    #expect(actualMarks.count == 2 && referenceMarks.count == 2)
    #expect(zip(actualMarks, referenceMarks).allSatisfy { abs($0 - $1) < 0.06 })
    let math = try #require(pdf.page(at: 11))
    // PDFKit substitutes display fonts when it exposes a selection as attributed text.
    // Read the embedded faces from the printed page that exercises both math and text.
    let pageData = try #require(math.dataRepresentation)
    let faces = String(decoding: pageData, as: UTF8.self).matches(of: #/\/BaseFont\s*\/(?:[A-Z]{6}\+)?([^/\s<>]+)/#)
        .map { String($0.output.1) }
    for face in ["CMUSansSerif-Bold", "CMUSansSerif-Oblique", "SurimonoMathSans-Regular"] {
        #expect(faces.contains(face))
    }
    for deck in [reference, pdf] {
        for (index, current, other) in [(6, "Records", "Soundings"), (10, "Soundings", "Records")] {
            let page = try #require(deck.page(at: index))
            let pixels = try PagePixels(page)
            func darkestRed(_ title: String) throws -> Int {
                let selection = try #require(deck.findString(title).first { $0.pages.contains(page) })
                let box = selection.bounds(for: page)
                let top = page.bounds(for: .mediaBox).maxY - box.maxY
                var minimum = 255
                for row in Int(top * 4)..<Int((top + box.height) * 4) {
                    for col in Int(box.minX * 4)..<Int(box.maxX * 4) {
                        minimum = min(minimum, pixels.color(atX: CGFloat(col) / 4, y: CGFloat(row) / 4).red)
                    }
                }
                return minimum
            }
            let selectedInk = try darkestRed(current)
            let shadedInk = try darkestRed(other)
            #expect(selectedInk + 70 < shadedInk && shadedInk < 250)
        }
    }
    let captions = try #require(pdf.page(at: 9))
    try checkBeamerReadingOrder(
        in: captions,
        words: ["Bench record", "Figure:", "The copper gauge", "Mark", "Depth", "Table:", "The morning reading"])
    for sample in [
        "Route", "A dry bench", "red notch", "blue line", "Yard stick", "Copper sleeve", "Inner pin", "Reading",
        "Example", "Harbour Crew", "Harbour Workshop",
    ] {
        let original = try #require(reference.findString(sample).first?.attributedString)
        let actual = try #require(pdf.findString(sample).first?.attributedString)
        func color(_ text: NSAttributedString) throws -> [Int] {
            let rgb = try #require(
                (text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB))
            return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        let actualColor = try color(actual)
        let expectedColor = try color(original)
        #expect(actualColor == expectedColor, "\(sample) インキ")
        let font = try #require(actual.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let refFont = try #require(original.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(abs(font.pointSize - refFont.pointSize) <= 0.2, "\(sample) 字の大きさ")
    }
    let page = try #require(pdf.page(at: 2))
    let ref = try #require(reference.page(at: 2))
    let pixels = try PagePixels(page)
    let refPixels = try PagePixels(ref)
    for (x, y) in [(36, 68), (58, 81), (81, 94)] {
        func marker(_ page: PagePixels) throws -> CGRect {
            var bounds = CGRect.null
            for py in (y - 10) * 4..<(y + 4) * 4 {
                for px in (x - 3) * 4..<(x + 12) * 4 {
                    let position = CGPoint(x: CGFloat(px) / 4, y: CGFloat(py) / 4)
                    let pixel = page.color(atX: position.x, y: position.y)
                    if pixel.blue - pixel.red > 40 {
                        bounds = bounds.union(CGRect(origin: position, size: CGSize(width: 0.25, height: 0.25)))
                    }
                }
            }
            try #require(!bounds.isNull)
            return bounds
        }
        let point = try marker(pixels)
        let target = try marker(refPixels)
        #expect(abs(point.minX - target.minX) <= 1 && abs(point.maxX - target.maxX) <= 1, "箇条書きの印 \(x) の横位置")
        #expect(
            abs(point.minY - target.minY) <= 1 && abs(point.maxY - target.maxY) <= 1,
            "箇条書きの印 \(x) の縦位置 \(point) TeX=\(target)")
        #expect(abs(point.height - target.height) <= 0.5, "箇条書きの印 \(x) の高さ \(point.height) TeX=\(target.height)")
    }
    let listFonts = String(decoding: try #require(page.dataRepresentation), as: UTF8.self)
    #expect(listFonts.contains("SurimonoMathSymbols") && !listFonts.contains("LucidaGrande"))
    let height = page.bounds(for: .mediaBox).height
    let width = page.bounds(for: .mediaBox).width
    for y in Int(height - 8)..<Int(height) {
        #expect(
            (0..<Int(width)).allSatisfy { pixels.color(atX: CGFloat($0), y: CGFloat(y)).red > 245 }, "スライド下端に罫線や操作部品がない"
        )
    }
}

@MainActor
private func checkBeamerReadingOrder(in page: PDFPage, words: [String]) throws {
    let text = try #require(page.string).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    var remaining = text[...]
    for word in words {
        let range = try #require(remaining.range(of: word), "\(word) の順序")
        remaining = remaining[range.upperBound...]
    }
}

@MainActor
private func checkSlideRules(
    in pdf: PDFDocument, against reference: PDFDocument, page index: Int, top: CGFloat, bottom: CGFloat, x: CGFloat
) throws {
    func rule(in deck: PDFDocument) throws -> CGRect {
        let page = try #require(deck.page(at: index))
        let y = page.bounds(for: .mediaBox).maxY - bottom
        return try printedInk(in: CGRect(x: x, y: y, width: 2, height: bottom - top), on: page)
    }
    let actual = try rule(in: pdf)
    let tex = try rule(in: reference)
    #expect(abs(actual.maxY - tex.maxY) <= 1, "p\(index + 1) 横罫=\(actual) TeX=\(tex)")
    let thicknessTolerance: CGFloat = tex.height < 1 ? 0.15 : 0.5
    #expect(abs(actual.height - tex.height) <= thicknessTolerance, "スライドの横罫の太さ")
}

@MainActor
private func checkBlockGap(
    in pdf: PDFDocument, against reference: PDFDocument, page index: Int, title: String, body: String
) throws {
    func gap(in deck: PDFDocument) throws -> CGFloat {
        let page = try #require(deck.page(at: index))
        let titleInk = try printedInk(of: title, in: deck, on: page)
        let bodyInk = try printedInk(of: body, in: deck, on: page)
        return titleInk.maxY - bodyInk.maxY
    }
    let actual = try gap(in: pdf)
    let tex = try gap(in: reference)
    #expect(abs(actual - tex) <= 1, "p\(index + 1) 「\(title)」→「\(body)」 間隔=\(actual) TeX=\(tex)")
}
