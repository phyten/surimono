import PDFKit
import SurimonoCore
import SurimonoRendering
import Testing

@MainActor
struct ViewPageDocumentTests {
    @Test("縦横のスクロールは横のページを縮めて選択文字とリンクを保つ", arguments: [0, 90, 270], ViewOptions.ScrollAxis.allCases)
    func mixedSizes(rotation: Int, axis: ViewOptions.ScrollAxis) throws {
        let source = try RenderingFixtures.pdf(count: 3, size: CGSize(width: 300, height: 500))
        if rotation == 0 {
            let landscape = try RenderingFixtures.pdf(size: CGSize(width: 500, height: 300))
            let page = try #require(StandalonePage.first(of: landscape))
            source.removePage(at: 1)
            source.insert(page, at: 1)
        }
        let wide = try #require(source.page(at: 1))
        wide.rotation = rotation
        let first = try #require(source.page(at: 0))
        let incoming = PDFAnnotation(
            bounds: CGRect(x: 10, y: 20, width: 80, height: 20), forType: .link, withProperties: nil)
        let destination = PDFDestination(page: wide, at: CGPoint(x: 100, y: 200))
        destination.zoom = 2
        incoming.action = PDFActionGoTo(destination: destination)
        first.addAnnotation(incoming)
        let outgoing = PDFAnnotation(
            bounds: CGRect(x: 50, y: 100, width: 100, height: 20), forType: .link, withProperties: nil)
        outgoing.url = URL(string: "https://example.com")
        wide.addAnnotation(outgoing)
        let sizes = [CGSize(width: 300, height: 500), CGSize(width: 500, height: 300), CGSize(width: 300, height: 500)]
        let options = ViewOptions(layout: .single, scrollAxis: axis, transition: .scroll, showsCoverAlone: false)
        let plan = ViewPageLayout(
            pageCount: 3, options: options, hasLogicalMargins: false, showsNumbers: false, pageSizes: sizes)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 0))
        let scaled = try #require(copy.page(at: 1))
        let box = scaled.bounds(for: .cropBox)
        #expect(abs((rotation == 0 ? box.width : box.height) - 300) < 0.01)
        #expect(wide.string?.contains("PAGE-") == true)
        #expect(scaled.string == wide.string)
        let link = try #require(scaled.annotations.first)
        #expect(link.url == outgoing.url)
        #expect(link.bounds == CGRect(x: 30, y: 60, width: 60, height: 12))
        let moved = try #require(copy.page(at: 0)?.annotations.first?.action as? PDFActionGoTo)
        #expect(moved.destination.page === scaled)
        #expect(moved.destination.point == CGPoint(x: 60, y: 120))
        #expect(abs(moved.destination.zoom - 10.0 / 3) < 0.001)
        #expect((incoming.action as? PDFActionGoTo)?.destination.page === wide)
        #expect(outgoing.bounds == CGRect(x: 50, y: 100, width: 100, height: 20))
        #expect(
            wide.bounds(for: .cropBox).size
                == (rotation == 0 ? CGSize(width: 500, height: 300) : CGSize(width: 300, height: 500)))
    }

    @Test("横スクロールは広いページと高いページを縮め小さいページを拡大しない", arguments: ViewOptions.Layout.allCases)
    func horizontalMixedSizes(layout: ViewOptions.Layout) throws {
        let source = try RenderingFixtures.pdf(count: 6, size: CGSize(width: 1000, height: 600))
        for index in 0..<6 {
            source.page(at: index)?.setBounds(CGRect(x: 0, y: 0, width: 500, height: 300), for: .cropBox)
        }
        source.page(at: 1)?.setBounds(CGRect(x: 20, y: 30, width: 300, height: 500), for: .cropBox)
        source.page(at: 3)?.setBounds(CGRect(x: 0, y: 0, width: 200, height: 100), for: .cropBox)
        source.page(at: 5)?.setBounds(CGRect(x: 0, y: 0, width: 1000, height: 200), for: .cropBox)
        let sizes = [
            CGSize(width: 500, height: 300), CGSize(width: 300, height: 500), CGSize(width: 500, height: 300),
            CGSize(width: 200, height: 100), CGSize(width: 500, height: 300), CGSize(width: 1000, height: 200),
        ]
        let options = ViewOptions(layout: layout, scrollAxis: .horizontal, transition: .scroll, showsCoverAlone: false)
        let plan = ViewPageLayout(
            pageCount: 6, options: options, hasLogicalMargins: false, showsNumbers: false, pageSizes: sizes)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 0))
        #expect(copy.page(at: 1)?.bounds(for: .cropBox) == CGRect(x: 12, y: 18, width: 180, height: 300))
        #expect(copy.page(at: 3)?.bounds(for: .cropBox).size == CGSize(width: 200, height: 100))
        #expect(copy.page(at: 5)?.bounds(for: .cropBox).size == CGSize(width: 500, height: 100))
    }

    @Test("縮小した線注釈は端点と線幅と破線を半分にし元の注釈を変えない", arguments: [false, true])
    func scaledLineAnnotation(reloaded: Bool) throws {
        let line = PDFAnnotation(
            bounds: CGRect(x: 40, y: 60, width: 200, height: 100), forType: .line, withProperties: nil)
        line.startPoint = CGPoint(x: 10, y: 20)
        line.endPoint = CGPoint(x: 190, y: 80)
        line.color = .red
        let border = PDFBorder()
        border.lineWidth = 8
        border.style = .dashed
        border.dashPattern = [12, 6]
        line.border = border
        let source = try annotationDocument(line, reloaded: reloaded)
        let original = try #require(source.page(at: 1)?.annotations.first)
        let before = try redBounds(on: #require(source.page(at: 1)))
        let copy = try halfSizeAnnotationDocument(source)
        let scaled = try #require(copy.page(at: 1)?.annotations.first)
        #expect(scaled !== original)
        #expect(scaled.bounds == CGRect(x: 20, y: 30, width: 100, height: 50))
        #expect(scaled.startPoint == CGPoint(x: 5, y: 10))
        #expect(scaled.endPoint == CGPoint(x: 95, y: 40))
        #expect(scaled.border !== original.border)
        #expect(scaled.border?.lineWidth == 4)
        #expect(scaled.border?.style == .dashed)
        #expect(scaled.border?.dashPattern as? [Int] == [6, 3])
        #expect(original.bounds == CGRect(x: 40, y: 60, width: 200, height: 100))
        #expect(original.startPoint == CGPoint(x: 10, y: 20))
        #expect(original.endPoint == CGPoint(x: 190, y: 80))
        #expect(original.border?.lineWidth == 8)
        #expect(original.border?.dashPattern as? [Int] == [12, 6])
        let after = try redBounds(on: #require(copy.page(at: 1)))
        #expect(abs(after.minX - before.minX / 2) <= 1)
        #expect(abs(after.minY - before.minY / 2) <= 1)
        #expect(abs(after.width - before.width / 2) <= 1)
        #expect(abs(after.height - before.height / 2) <= 1)
    }

    @Test("縮小した手書き注釈は全パスと曲線の制御点と線幅を半分にし元のパスを変えない", arguments: [false, true])
    func scaledInkAnnotation(reloaded: Bool) throws {
        let ink = PDFAnnotation(
            bounds: CGRect(x: 40, y: 60, width: 200, height: 100), forType: .ink, withProperties: nil)
        ink.color = .red
        let border = PDFBorder()
        border.lineWidth = 8
        ink.border = border
        let curve = NSBezierPath()
        curve.move(to: CGPoint(x: 10, y: 20))
        curve.curve(
            to: CGPoint(x: 190, y: 80), controlPoint1: CGPoint(x: 60, y: 10), controlPoint2: CGPoint(x: 160, y: 90))
        ink.add(curve)
        let segment = NSBezierPath()
        segment.move(to: CGPoint(x: 20, y: 90))
        segment.line(to: CGPoint(x: 80, y: 90))
        ink.add(segment)
        let source = try annotationDocument(ink, reloaded: reloaded)
        let original = try #require(source.page(at: 1)?.annotations.first)
        let before = try redBounds(on: #require(source.page(at: 1)))
        let originalPaths = try #require(original.paths)
        let originalBounds = originalPaths.map(\.controlPointBounds)
        let copy = try halfSizeAnnotationDocument(source)
        let scaled = try #require(copy.page(at: 1)?.annotations.first)
        let paths = try #require(scaled.paths)
        #expect(scaled.bounds == CGRect(x: 20, y: 30, width: 100, height: 50))
        #expect(scaled.border?.lineWidth == 4)
        #expect(paths.count == 2)
        for (index, path) in paths.enumerated() {
            #expect(path !== originalPaths[index])
            let expected = originalBounds[index]
            #expect(
                path.controlPointBounds
                    == CGRect(
                        x: expected.minX / 2, y: expected.minY / 2, width: expected.width / 2,
                        height: expected.height / 2))
        }
        if !reloaded {
            var points = [NSPoint](repeating: .zero, count: 3)
            #expect(paths[0].element(at: 1, associatedPoints: &points) == .curveTo)
            #expect(points == [CGPoint(x: 30, y: 5), CGPoint(x: 80, y: 45), CGPoint(x: 95, y: 40)])
        }
        #expect(original.bounds == CGRect(x: 40, y: 60, width: 200, height: 100))
        #expect(original.border?.lineWidth == 8)
        #expect(original.paths?.map(\.controlPointBounds) == originalBounds)
        #expect(originalPaths.map(\.controlPointBounds) == originalBounds)
        let after = try redBounds(on: #require(copy.page(at: 1)))
        #expect(abs(after.minX - before.minX / 2) <= 1)
        #expect(abs(after.minY - before.minY / 2) <= 1)
        #expect(abs(after.width - before.width / 2) <= 1)
        #expect(abs(after.height - before.height / 2) <= 1)
    }

    @Test("手書きパスの線幅と破線と描画精度も縮め線端と結合の種類は保つ")
    func scaledInkDrawingDimensions() throws {
        let ink = PDFAnnotation(
            bounds: CGRect(x: 40, y: 60, width: 200, height: 100), forType: .ink, withProperties: nil)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 10, y: 20))
        path.line(to: CGPoint(x: 190, y: 80))
        path.lineWidth = 10
        path.flatness = 0.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .bevel
        path.miterLimit = 8
        path.setLineDash([10, 4], count: 2, phase: 2)
        ink.add(path)
        let source = try annotationDocument(ink, reloaded: false)
        let copy = try halfSizeAnnotationDocument(source)
        let scaled = try #require(copy.page(at: 1)?.annotations.first?.paths?.first)
        #expect(scaled.lineWidth == 5)
        #expect(scaled.flatness == 0.3)
        #expect(scaled.lineCapStyle == .round && scaled.lineJoinStyle == .bevel)
        #expect(scaled.miterLimit == 8)
        var pattern: [CGFloat] = [0, 0]
        var count = 2
        var phase: CGFloat = 0
        scaled.getLineDash(&pattern, count: &count, phase: &phase)
        #expect(pattern == [5, 2] && count == 2 && phase == 1)
        #expect(path.lineWidth == 10 && path.flatness == 0.6)
        path.getLineDash(&pattern, count: &count, phase: &phase)
        #expect(pattern == [10, 4] && count == 2 && phase == 2)
    }

    @Test("縮小した文字注釈は文字サイズと枠線も半分にし元を変えない")
    func scaledTextAnnotation() throws {
        let note = PDFAnnotation(
            bounds: CGRect(x: 40, y: 60, width: 200, height: 100), forType: .freeText, withProperties: nil)
        note.contents = "Annotation"
        note.font = NSFont.systemFont(ofSize: 24)
        let border = PDFBorder()
        border.lineWidth = 6
        note.border = border
        let source = try annotationDocument(note, reloaded: false)
        let copy = try halfSizeAnnotationDocument(source)
        let scaled = try #require(copy.page(at: 1)?.annotations.first)
        #expect(scaled.font?.pointSize == 12)
        #expect(scaled.border?.lineWidth == 3)
        #expect(note.font?.pointSize == 24)
        #expect(note.border?.lineWidth == 6)
    }

    private func annotationDocument(_ annotation: PDFAnnotation, reloaded: Bool) throws -> PDFDocument {
        let source = try RenderingFixtures.pdf(count: 3, size: CGSize(width: 400, height: 400))
        source.page(at: 0)?.setBounds(CGRect(x: 0, y: 0, width: 200, height: 200), for: .cropBox)
        source.page(at: 2)?.setBounds(CGRect(x: 0, y: 0, width: 200, height: 200), for: .cropBox)
        source.page(at: 1)?.addAnnotation(annotation)
        guard reloaded else { return source }
        let data = try #require(source.dataRepresentation())
        return try #require(PDFDocument(data: data))
    }

    private func halfSizeAnnotationDocument(_ source: PDFDocument) throws -> PDFDocument {
        let plan = ViewPageLayout(
            pageCount: 3,
            options: ViewOptions(layout: .single, scrollAxis: .horizontal, transition: .scroll, showsCoverAlone: false),
            hasLogicalMargins: false, showsNumbers: false,
            pageSizes: [
                CGSize(width: 200, height: 200), CGSize(width: 400, height: 400), CGSize(width: 200, height: 200),
            ])
        return try #require(ViewPageDocument.make(source, plan: plan, margin: 0))
    }

    private func redBounds(on page: PDFPage) throws -> CGRect {
        let size = page.bounds(for: .cropBox).size
        let width = Int(size.width)
        let height = Int(size.height)
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        page.draw(with: .cropBox, to: context)
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var bounds = CGRect.null
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if pixels[offset] > 180 && pixels[offset + 1] < 100 && pixels[offset + 2] < 100 {
                    bounds = bounds.union(CGRect(x: x, y: height - 1 - y, width: 1, height: 1))
                }
            }
        }
        #expect(!bounds.isNull)
        return bounds
    }

    @Test("縮小したページへのリンクは未指定の座標と倍率を保つ")
    func unspecifiedDestination() throws {
        let source = try RenderingFixtures.pdf(count: 3, size: CGSize(width: 300, height: 500))
        let first = try #require(source.page(at: 0))
        let wide = try #require(source.page(at: 1))
        wide.rotation = 90
        let destination = PDFDestination(page: wide, at: CGPoint(x: kPDFDestinationUnspecifiedValue, y: 200))
        destination.zoom = kPDFDestinationUnspecifiedValue
        let link = PDFAnnotation(
            bounds: CGRect(x: 20, y: 20, width: 50, height: 20), forType: .link, withProperties: nil)
        link.destination = destination
        first.addAnnotation(link)
        let plan = ViewPageLayout(
            pageCount: 3,
            options: ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false),
            hasLogicalMargins: false, showsNumbers: false,
            pageSizes: [
                CGSize(width: 300, height: 500), CGSize(width: 500, height: 300), CGSize(width: 300, height: 500),
            ])
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 0))
        let moved = try #require(copy.page(at: 0)?.annotations.first?.destination)
        #expect(moved.point.x == kPDFDestinationUnspecifiedValue)
        #expect(moved.point.y == 120)
        #expect(moved.zoom == kPDFDestinationUnspecifiedValue)
        #expect(moved.page === copy.page(at: 1))
    }

    @Test("縮小した見開きの番号と変更の印も本文と同じ倍率で配置する")
    func scaledDecorations() throws {
        let source = try RenderingFixtures.pdf(count: 4, size: CGSize(width: 300, height: 500))
        let landscape = try RenderingFixtures.pdf(size: CGSize(width: 500, height: 300))
        source.removePage(at: 2)
        source.insert(try #require(StandalonePage.first(of: landscape)), at: 2)
        let plan = ViewPageLayout(
            pageCount: 4,
            options: ViewOptions(layout: .spread, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false),
            hasLogicalMargins: false, showsNumbers: true,
            pageSizes: [
                CGSize(width: 300, height: 500), CGSize(width: 300, height: 500), CGSize(width: 500, height: 300),
                CGSize(width: 300, height: 500),
            ])
        let copy = try #require(
            ViewPageDocument.make(
                source, plan: plan, margin: 20,
                changeMarks: [ChangeMark(pageIndex: 2, rect: CGRect(x: 30, y: 100, width: 100, height: 40))]))
        let page = try #require(copy.page(at: 2))
        #expect(
            page.selection(for: CGRect(x: 100, y: 0, width: 100, height: 12))?.string?.trimmingCharacters(
                in: .whitespacesAndNewlines) == "3")
        let pixel = try RenderingFixtures.pixel(page, x: 9, y: 70)
        #expect(pixel[0] > 200 && pixel[1] < 200 && pixel[2] < 200)
        #expect(source.page(at: 2)?.bounds(for: .cropBox).size == CGSize(width: 500, height: 300))
    }

    @Test("縦横の画像の束も表示コピーだけを縮め印刷用の寸法を変えない", arguments: ViewOptions.ScrollAxis.allCases)
    func mixedImageBundle(axis: ViewOptions.ScrollAxis) async throws {
        let portrait = try RenderingFixtures.image(orientation: 6)
        let landscape = try RenderingFixtures.image()
        let images = [portrait, landscape, portrait].enumerated().map {
            DocumentSource.Image(data: $0.element, fileURL: URL(fileURLWithPath: "/fixtures/image-\($0.offset).tiff"))
        }
        let settings = RenderSettings(
            layout: .a4Single, theme: PrintTheme(id: "test", name: "Test", css: ""),
            preset: HTMLCleanupPreset(id: "none", name: "None"), options: PrintOptions(marginsInMillimeters: 0))
        let renderer = DocumentRenderer()
        let prepared = try await renderer.prepare(.images(images), settings: settings)
        let result = try await renderer.composeSheet(for: prepared)
        let source = prepared.viewDocument
        let sizes = (0..<source.pageCount).map { source.page(at: $0)!.bounds(for: .cropBox).size }
        let printed = result.sheetDocument.page(at: 1)?.bounds(for: .mediaBox)
        let plan = ViewPageLayout(
            pageCount: source.pageCount,
            options: ViewOptions(layout: .single, scrollAxis: axis, transition: .scroll, showsCoverAlone: false),
            hasLogicalMargins: false, showsNumbers: false, pageSizes: sizes)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 0))
        #expect(sizes[1].width > sizes[0].width)
        #expect(abs(copy.page(at: 1)!.bounds(for: .cropBox).width - sizes[0].width) < 0.01)
        #expect(source.page(at: 1)?.bounds(for: .cropBox).size == sizes[1])
        #expect(result.sheetDocument.page(at: 1)?.bounds(for: .mediaBox) == printed)
    }

    @Test("表示用の切り取りは元のページと選択できる本文を変えない", arguments: [0.0, 42.0])
    func cropping(margin: Double) throws {
        let source = try RenderingFixtures.pdf(count: 3, size: CGSize(width: 300, height: 500))
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .scroll, showsCoverAlone: false)
        let plan = ViewPageLayout(pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: true)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: margin))
        #expect(copy.page(at: 0)?.bounds(for: .cropBox) == CGRect(x: 0, y: margin, width: 300, height: 500 - margin))
        #expect(
            copy.page(at: 1)?.bounds(for: .cropBox) == CGRect(x: 0, y: margin, width: 300, height: 500 - 2 * margin))
        #expect(copy.page(at: 2)?.bounds(for: .cropBox) == CGRect(x: 0, y: 0, width: 300, height: 500 - margin))
        for index in 0..<3 {
            #expect(source.page(at: index)?.bounds(for: .cropBox) == CGRect(x: 0, y: 0, width: 300, height: 500))
            #expect(copy.page(at: index)?.string == source.page(at: index)?.string)
        }
    }

    @Test("結合する辺だけを切り取り縦横と左右の読む順に応じて外端を残す", arguments: ViewOptions.ScrollAxis.allCases, ViewOptions.Direction.allCases)
    func cropAxes(axis: ViewOptions.ScrollAxis, direction: ViewOptions.Direction) throws {
        let source = try RenderingFixtures.pdf(count: 3, size: CGSize(width: 300, height: 500))
        let options = ViewOptions(
            layout: .single, direction: direction, scrollAxis: axis, transition: .scroll, showsCoverAlone: false)
        let plan = ViewPageLayout(pageCount: 3, options: options, hasLogicalMargins: true, showsNumbers: false)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 42))
        let expected: [CGRect]
        if axis == .vertical {
            expected = [
                CGRect(x: 0, y: 42, width: 300, height: 458),
                CGRect(x: 0, y: 42, width: 300, height: 416),
                CGRect(x: 0, y: 0, width: 300, height: 458),
            ]
        } else if direction == .leftToRight {
            expected = [
                CGRect(x: 0, y: 0, width: 258, height: 500),
                CGRect(x: 42, y: 0, width: 216, height: 500),
                CGRect(x: 42, y: 0, width: 258, height: 500),
            ]
        } else {
            expected = [
                CGRect(x: 42, y: 0, width: 258, height: 500),
                CGRect(x: 42, y: 0, width: 216, height: 500),
                CGRect(x: 0, y: 0, width: 258, height: 500),
            ]
        }
        for index in 0..<3 {
            #expect(copy.page(at: index)?.bounds(for: .cropBox) == expected[index])
            #expect(source.page(at: index)?.bounds(for: .cropBox) == CGRect(x: 0, y: 0, width: 300, height: 500))
        }
    }

    @Test("見開きの空白を挿入しても内部リンクと注釈はコピー内の論理ページを指す")
    func links() throws {
        let source = try RenderingFixtures.pdf(count: 2, size: CGSize(width: 300, height: 500))
        let first = try #require(source.page(at: 0))
        let second = try #require(source.page(at: 1))
        let link = PDFAnnotation(
            bounds: CGRect(x: 20, y: 200, width: 100, height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: second, at: CGPoint(x: 50, y: 400)))
        first.addAnnotation(link)
        let options = ViewOptions(layout: .spread, scrollAxis: .horizontal, transition: .slide, showsCoverAlone: true)
        let plan = ViewPageLayout(pageCount: 2, options: options, hasLogicalMargins: false, showsNumbers: true)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 0))
        #expect(copy.pageCount == 4)
        #expect(copy.page(at: 0)?.string?.isEmpty != false)
        #expect(copy.page(at: 3)?.string?.isEmpty != false)
        #expect(copy.page(at: 0)?.bounds(for: .cropBox) == first.bounds(for: .cropBox))
        let moved = try #require(copy.page(at: 1)?.annotations.first?.action as? PDFActionGoTo)
        #expect(moved.destination.page === copy.page(at: 2))
        #expect(moved.destination.point == CGPoint(x: 50, y: 400))
        #expect((link.action as? PDFActionGoTo)?.destination.page === second)
        #expect(link.page === first)
        #expect(first.annotations.count == 1)
        #expect(source.pageCount == 2)
        #expect(copy.page(at: 1)?.string?.contains("PAGE-1") == true)
        #expect(first.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "PAGE-1")
    }

    @Test("表示番号は通常のPDFに描き込まれ本文の座標と寸法を変えない", arguments: [0.0, 42.0])
    func viewNumbers(margin: Double) throws {
        let source = try RenderingFixtures.pdf(count: 1, size: CGSize(width: 300, height: 500))
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false)
        let plan = ViewPageLayout(pageCount: 1, options: options, hasLogicalMargins: true, showsNumbers: true)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: margin))
        let page = try #require(copy.page(at: 0))
        let original = try #require(source.page(at: 0))
        #expect(type(of: page) == PDFPage.self)
        #expect(page.bounds(for: .mediaBox) == original.bounds(for: .mediaBox))
        let before = try #require(source.findString("PAGE-1", withOptions: []).first)
        let after = try #require(copy.findString("PAGE-1", withOptions: []).first)
        #expect(before.bounds(for: original) == after.bounds(for: page))
        let footer = try #require(page.selection(for: CGRect(x: 100, y: 0, width: 100, height: 42)))
        #expect(footer.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        #expect(footer.bounds(for: page).minY >= 0)
        #expect(original.selection(for: CGRect(x: 100, y: 0, width: 100, height: 42))?.string?.isEmpty != false)
    }

    @Test("回転と原点のあるページでも表示番号は見た目の下余白に入る", arguments: [0, 90, 180, 270])
    func rotatedNumbers(rotation: Int) throws {
        let source = try RenderingFixtures.pdf(count: 1, size: CGSize(width: 300, height: 500))
        let original = try #require(source.page(at: 0))
        let crop = CGRect(x: 20, y: 30, width: 260, height: 440)
        original.setBounds(crop, for: .cropBox)
        original.rotation = rotation
        let options = ViewOptions(
            layout: .single, scrollAxis: .horizontal, transition: .instant, showsCoverAlone: false)
        let plan = ViewPageLayout(pageCount: 1, options: options, hasLogicalMargins: true, showsNumbers: true)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 42))
        let page = try #require(copy.page(at: 0))
        #expect(page.bounds(for: .cropBox) == crop)
        #expect(page.rotation == rotation)
        let footer: CGRect
        switch rotation {
        case 90: footer = CGRect(x: 238, y: 200, width: 42, height: 100)
        case 180: footer = CGRect(x: 100, y: 428, width: 100, height: 42)
        case 270: footer = CGRect(x: 20, y: 200, width: 42, height: 100)
        default: footer = CGRect(x: 100, y: 30, width: 100, height: 42)
        }
        #expect(page.selection(for: footer)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    @Test("番号入り表示PDFはワーカースレッドで通常のPDFPageとして描画できる")
    func backgroundDrawing() async throws {
        let source = try RenderingFixtures.pdf(count: 1, size: CGSize(width: 300, height: 500))
        let options = ViewOptions(layout: .single, scrollAxis: .vertical, transition: .instant, showsCoverAlone: false)
        let plan = ViewPageLayout(pageCount: 1, options: options, hasLogicalMargins: true, showsNumbers: true)
        let copy = try #require(ViewPageDocument.make(source, plan: plan, margin: 42))
        let data = try #require(copy.dataRepresentation())
        // Only immutable PDF bytes cross the actor boundary; the worker owns its document and drawing context.
        let drawn = await Task.detached { Self.drawOnWorker(data) }.value
        #expect(drawn)
    }

    private nonisolated static func drawOnWorker(_ data: Data) -> Bool {
        guard !Thread.isMainThread else { return false }
        guard let document = PDFDocument(data: data), let page = document.page(at: 0),
            let context = CGContext(
                data: nil, width: 300, height: 500, bitsPerComponent: 8, bytesPerRow: 1200,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 500))
        withExtendedLifetime(document) { page.draw(with: .cropBox, to: context) }
        guard let data = context.data else { return false }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        // The footer was empty in the source. Rendering the baked number must leave ink there.
        let hasFooterInk = (0..<42).contains { y in
            (100..<200).contains { x in pixels[((499 - y) * 300 + x) * 4] < 128 }
        }
        return hasFooterInk && page.string?.contains("PAGE-1") == true
    }

    @Test("印刷の番号は余白ゼロでも紙の内側にあり本文の位置と用紙寸法を変えない", arguments: [0.0, 15.0])
    func printedNumbers(margin: Double) async throws {
        let source = try RenderingFixtures.pdf(count: 1, size: PaperSize.a4.size)
        let plain = try await PDFComposer().compose(
            source, layout: .a4Single, options: PrintOptions(marginsInMillimeters: margin))
        let numbered = try await PDFComposer().compose(
            source, layout: .a4Single, options: PrintOptions(marginsInMillimeters: margin, showsPageNumbers: true))
        let before = try #require(plain.page(at: 0))
        let after = try #require(numbered.page(at: 0))
        #expect(after.bounds(for: .mediaBox) == before.bounds(for: .mediaBox))
        let beforeText = try #require(plain.findString("PAGE-1", withOptions: []).first)
        let afterText = try #require(numbered.findString("PAGE-1", withOptions: []).first)
        #expect(afterText.bounds(for: after) == beforeText.bounds(for: before))
        let footer = try #require(after.selection(for: CGRect(x: 250, y: 0, width: 100, height: 42)))
        #expect(footer.string?.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
        #expect(footer.bounds(for: after).minY >= 0)
        #expect(footer.bounds(for: after).maxY < (margin == 0 ? 15 : 42))
    }
}
