import Foundation
import SurimonoCore

@MainActor
public enum HTMLExporter {
    public static func html(
        source: DocumentSource, settings: RenderSettings, title: String
    ) async throws -> String {
        try await prepared(source: source, settings: settings, title: title, richText: false).html
    }

    public static func richText(
        source: DocumentSource, settings: RenderSettings, title: String
    ) async throws -> RichTextExport {
        let result = try await prepared(source: source, settings: settings, title: title, richText: true)
        return try RichTextExport(html: result.html, figures: result.figures)
    }

    private static func prepared(
        source: DocumentSource, settings: RenderSettings, title: String, richText: Bool
    ) async throws -> (html: String, figures: [RichTextFigure]) {
        let renderer = DocumentRenderer()
        var candidate = settings
        if source.format == .latex, settings.theme.formats == [.latex], settings.latexComposition != .document {
            let info = renderer.latexClassInfo(for: source, composition: settings.latexComposition)
            let landscape =
                settings.paperOrientation == .auto
                ? info.pageBox.paperWidth > info.pageBox.paperHeight : settings.paperOrientation == .landscape
            candidate.layout = settings.layout.oriented(settings.layout.kind != .booklet && landscape)
            candidate.applyLaTeXPage(info)
        } else {
            candidate.latexComposition = .document
        }
        func convert(_ input: RenderSettings) async throws -> HTMLFragment {
            guard
                let fragment = try await Task.detached(
                    priority: .utility,
                    operation: {
                        try DocumentRenderer.themedFragment(
                            source, pageBreakLine: input.finish.breaks.customLine, proof: input.finish.proof,
                            orgReading: input.orgReading,
                            composition: input.latexComposition,
                            textWidthPoints: input.textWidthPoints(in: input.layout), textScale: input.textScale)
                    }
                ).value
            else { throw DocumentRenderer.RenderingError.unsupportedFormat }
            return fragment
        }
        var fragment = try await convert(candidate)
        if candidate.latexComposition != .document && fragment.latexClass?.composition == .document {
            // An included body may have its own columns. Restore the same widths as the ordinary export.
            candidate = settings
            candidate.latexComposition = .document
            fragment = try await convert(candidate)
        }
        let settings = candidate
        var body = fragment
        body.body = settings.finish.links.apply(to: fragment.body, language: settings.pageLanguage)
        let directory = source.fileURL?.deletingLastPathComponent()
        let html = try await DocumentRenderer.builtHTML(body, source: source, settings: settings, separatesPaper: false)
        let input = renderer.exportSource(
            .html(html, baseURL: directory ?? FileManager.default.temporaryDirectory),
            for: source)
        let slide = fragment.latexClass?.beamerPageSize
        let size = slide ?? settings.layout.logicalPageSize(options: settings.options)
        let margins = WebPaginator.Margins(
            slide == nil ? settings.layout.logicalMargins(options: settings.options) : .zero)
        let code =
            CodeFitScript.javaScript(
                for: settings.code,
                layoutWidth: (size.width - margins.left - margins.right) * WebPaginator.printPixelsPerPoint) ?? ""
        let graphicWidth =
            slide == nil
            ? size.width - margins.left - margins.right : fragment.latexClass?.pageBox.textWidth ?? size.width
        let graphic =
            source.format == .latex
            ? LaTeXGraphicPreparation.script(
                in: body.body,
                layoutWidth: graphicWidth * WebPaginator.printPixelsPerPoint,
                layoutHeight: settings.theme.formats == [.latex]
                    ? (size.height - margins.top - margins.bottom) * WebPaginator.printPixelsPerPoint : nil)
            : nil
        let slideScript = slide == nil ? nil : try DocumentRenderer.beamerPreparation()
        let preparation = [graphic, code, slideScript ?? settings.theme.script].compactMap { $0 }.joined(
            separator: "\n")
        let composedHTML = !richText && (fragment.latexClass?.composition ?? .document) != .document
        let shift = settings.mirrorsLaidOutPages ? settings.layout.versoContentShift(options: settings.options) : 0
        let result = try await WebPaginator().paginateWithResult(
            input, pageSize: size, margins: margins,
            allowsJavaScript: false, preparationScript: preparation, rendersMermaid: true, rendersDiagrams: true,
            exportHTMLTitle: title, richText: richText,
            richTextTypeface: Typeface.isAvailable(
                themeID: settings.theme.id, usesPrintTheme: source.format.usesPrintTheme)
                ? settings.typeface : .style,
            htmlComposition: composedHTML ? .init(versoShift: shift, rightBound: settings.layout.isRightBound) : nil,
            composesLaTeXParagraphs: composedHTML)
        guard let exported = result.exportedHTML else { throw WebPaginator.PaginationError.emptyDocument }
        return (exported, result.richTextFigures)
    }

    // Only bytes WebKit accepted as an image may leave the app. An img pointing at an arbitrary local text file
    // must fail rather than embedding that file's bytes in an apparently harmless data URI.
    static let imageResourceScript = #"""
        return Array.from(document.images).flatMap(image => {
          const url = image.currentSrc || image.src;
          if (/^(https?:|data:)/i.test(url)) return [];
          if (!image.complete || !image.naturalWidth)
            throw new Error('A local image could not be embedded.');
          return [url];
        });
        """#

    // Serialize a clone so cleanup cannot change the prepared document. Resource bytes come through the same
    // sandbox handler as pagination; the exporter never grants access to a folder the reader did not authorize.
    static let serializationScript = #"""
        const copy = document.documentElement.cloneNode(true);
        // Match the clone before pruning, while its elements still line up with the source.
        const elementFonts = new Map();
        if (richText) {
          const keepFonts = el => getComputedStyle(el).fontFamily.split(',').map(f => f.trim())
            .filter(f => systemFonts.includes(f.replace(/^['"]|['"]$/g,''))).join(', ');
          const selector = copiesTypeface ? 'body, h1,h2,h3,h4,h5,h6,p,table,th,td,caption,figcaption,blockquote,li,div,span,code,pre,kbd,samp,strong' : 'body,h1,h2,h3,h4,h5,h6';
          const originalElements = Array.from(document.querySelectorAll(selector));
          Array.from(copy.querySelectorAll(selector)).forEach((el,i) => elementFonts.set(el,keepFonts(originalElements[i])));
        }
        const originals = Array.from(document.images);
        const images = Array.from(copy.querySelectorAll('img'));
        for (let i = 0; i < images.length; i++) {
          const original = originals[i], image = images[i];
          const url = original.currentSrc || original.src;
          image.removeAttribute('srcset');
          if (/^https?:/i.test(url) || /^data:/i.test(url)) { image.src = url; continue; }
          if (!embeddedImages[url]) throw new Error('A local image could not be embedded.');
          image.src = embeddedImages[url];
        }
        copy.querySelectorAll('script,base,meta[http-equiv],meta[name=author],link,iframe,object,embed,picture source,template').forEach(el => el.remove());
        // Only the generated LaTeX body carries these class options. Retain their finite values
        // for the print stylesheet without opening the data-attribute filter to arbitrary source metadata.
        const latexBody = copy.querySelector('body.format-latex');
        for (const el of [copy, ...copy.querySelectorAll('*')]) {
          for (const attr of Array.from(el.attributes)) {
            if (latexBody && el.closest('.beamer-frame') &&
                /^(data-align|data-kind|data-plain|data-shaded|data-squeeze|data-beamer-covered|data-text-width)$/.test(attr.name)) continue;
            if (composedHTML && /^data-latex-(size|class|chapters|title-layout|js-toc|js-chapters|js-twocolumn|heading|float|column|placement|caption-style|caption-hang|tabularx|rule-line|breakable|undotted|text-size)$/.test(attr.name) &&
                /^[a-zA-Z0-9 *._-]{0,50}$/.test(attr.value)) continue;
            if (el === latexBody && ((attr.name === 'data-latex-size' && /^(10|11|12)$/.test(attr.value)) ||
                (attr.name === 'data-latex-chapters' && /^(true|false)$/.test(attr.value)))) continue;
            if (/^on/i.test(attr.name) || /^(javascript|vbscript):/i.test(attr.value.trim()) || (attr.name.startsWith('data-') && !['data-deco','data-no','data-code-label','data-syntax','data-callout'].includes(attr.name)) ||
                /file:\/\/|surimono-local:|surimono-snapshot:/i.test(attr.value)) el.removeAttribute(attr.name);
          }
        }
        for (const style of copy.querySelectorAll('style')) {
          style.textContent = style.textContent.replace(/@import\s+[^;]*;/gi, '').replace(/url\(\s*['"]?(?:file:|surimono-local:)[^)]*\)/gi, 'none');
        }
        const comments = document.createTreeWalker(copy, NodeFilter.SHOW_COMMENT);
        const removed = []; while (comments.nextNode()) removed.push(comments.currentNode);
        removed.forEach(node => node.remove());
        const head = copy.querySelector('head');
        copy.querySelectorAll('title,meta[charset]').forEach(el => el.remove());
        const charset = document.createElement('meta'); charset.setAttribute('charset', 'utf-8'); head.prepend(charset);
        const titleNode = document.createElement('title'); titleNode.textContent = title; head.append(titleNode);
        if (richText) {
          const body = copy.querySelector('body');
          head.replaceChildren(charset,titleNode);
          body.querySelectorAll('style,noscript,video,audio,canvas,source,meta,[hidden]').forEach(el => el.remove());
          const figures = [];
          const sizes = new Map(images.map((img,i) => [img,originals[i].getBoundingClientRect()]));
          const allowed = new Set((
            'a abbr address article aside b blockquote br caption code dd del details div dl dt em figcaption ' +
            'figure footer h1 h2 h3 h4 h5 h6 header hr i img ins kbd li main mark ol p pre q rp rt ruby ' +
            's samp section small span strong sub summary sup table tbody td tfoot th thead tr u ul var'
          ).split(' '));
          const bitmap = /^data:image\/(png|jpeg|gif|webp|tiff|bmp|avif|heic|heif|x-icon|vnd\.microsoft\.icon);/i;
          for (const el of [copy,head,body,...body.querySelectorAll('*')]) {
            if (el !== copy && el !== head && el !== body && !allowed.has(el.localName)) {
              el.replaceWith(...el.childNodes); continue;
            }
            const align = el.style.verticalAlign;
            for (const attr of Array.from(el.attributes)) {
              if (['lang','dir','id','colspan','rowspan','start','value','type','alt'].includes(attr.name)) continue;
              if (el.localName === 'img' && attr.name === 'src' && bitmap.test(attr.value)) continue;
              if (el.localName === 'a' && attr.name === 'href' && /^(https?:|mailto:|#)/i.test(attr.value)) continue;
              el.removeAttribute(attr.name);
            }
            if (el.localName === 'img') {
              const r = sizes.get(el);
              if (!el.hasAttribute('src') || !r?.width || !r.height) {
                el.replaceWith(document.createTextNode(el.alt)); continue;
              }
              el.setAttribute('width', r.width); el.setAttribute('height', r.height);
              el.style.width = r.width + 'px'; el.style.height = r.height + 'px';
              if (align) el.style.verticalAlign = align;
              figures.push({width:r.width,height:r.height,alt:el.alt});
            }
            if (el.localName === 'table') {
              el.setAttribute('border', '1'); el.setAttribute('cellpadding', '4');
            }
          }
          for (const [element,font] of elementFonts) element.style.fontFamily = font;
          const style = document.createElement('style'); style.textContent = pasteCSS; head.append(style);
          return {html:'<!DOCTYPE html>\n' + copy.outerHTML, figures};
        }
        const screen = document.createElement('style');
        // Class styles already center a measured text block. Put the screen gutter around the paper
        // so it neither replaces that measure with 52rem nor consumes part of the text width.
        const classMeasure = latexBody && getComputedStyle(document.body).getPropertyValue('--tex-width');
        const screenLayout = classMeasure ? 'html { padding:2rem clamp(1rem,4vw,3rem); }' :
          'body { box-sizing:border-box; max-width:52rem; margin-inline:auto; padding:2rem clamp(1rem,4vw,3rem); }';
        screen.textContent = '@media screen { ' + screenLayout + ' img,svg { max-width:100%; } }';
        if (latexBody?.querySelector('.beamer-frame')) {
          // A standalone browser uses 96 CSS pixels per inch; AppKit's print view uses 90.
          const style = getComputedStyle(document.body);
          const w = parseFloat(style.getPropertyValue('--beamer-width')) / 1.25;
          const h = parseFloat(style.getPropertyValue('--beamer-height')) / 1.25;
          screen.textContent = '@page { size:' + w + 'pt ' + h + 'pt; margin:0 } ' +
            '@media print { body.surimono.format-latex { zoom:' + (96/90) + ' } } ' +
            '@media screen { body.format-latex > .beamer-frame { margin:1rem auto; outline:1px solid #ddd; } }';
        }
        head.append(screen);
        return '<!DOCTYPE html>\n' + copy.outerHTML;
        """#
}
