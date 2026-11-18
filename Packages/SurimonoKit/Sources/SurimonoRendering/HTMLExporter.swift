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
        guard
            let fragment = try await Task.detached(
                priority: .utility,
                operation: {
                    try DocumentRenderer.themedFragment(
                        source, pageBreakLine: settings.finish.breaks.customLine,
                        proof: settings.finish.proof)
                }
            ).value
        else { throw DocumentRenderer.RenderingError.unsupportedFormat }
        let body = HTMLFragment(
            body: settings.finish.links.apply(to: fragment.body, language: settings.pageLanguage),
            title: fragment.title, language: fragment.language)
        let directory = source.fileURL?.deletingLastPathComponent()
        let html = HTMLDocumentBuilder.build(
            fragment: body, format: source.format, theme: settings.theme,
            baseURL: directory, language: settings.pageLanguage, textScale: settings.textScale,
            finish: settings.finish.styleSheet, code: settings.code)
        let input = DocumentRenderer().exportSource(
            .html(html, baseURL: directory ?? FileManager.default.temporaryDirectory),
            for: source)
        let size = settings.layout.logicalPageSize(options: settings.options)
        let margins = WebPaginator.Margins(settings.layout.logicalMargins(options: settings.options))
        let code =
            CodeFitScript.javaScript(
                for: settings.code,
                layoutWidth: (size.width - margins.left - margins.right) * WebPaginator.printPixelsPerPoint) ?? ""
        let preparation = code + "\n" + (settings.theme.script ?? "")
        let result = try await WebPaginator().paginateWithResult(
            input, pageSize: size, margins: margins,
            allowsJavaScript: false, preparationScript: preparation, rendersMermaid: true, rendersDiagrams: true,
            exportHTMLTitle: title, richText: richText)
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
        for (const el of [copy, ...copy.querySelectorAll('*')]) {
          for (const attr of Array.from(el.attributes)) {
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
          const keepFonts = el => getComputedStyle(el).fontFamily.split(',').map(f => f.trim())
            .filter(f => systemFonts.includes(f.replace(/^['"]|['"]$/g,''))).join(', ');
          const bodyFont = keepFonts(document.body);
          const headings = 'h1,h2,h3,h4,h5,h6';
          const originalsByHeading = Array.from(document.body.querySelectorAll(headings));
          const headingFonts = new Map(Array.from(body.querySelectorAll(headings),
            (el,i) => [el,keepFonts(originalsByHeading[i])]));
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
          if (bodyFont) body.style.fontFamily = bodyFont;
          for (const [heading,font] of headingFonts) heading.style.fontFamily = font;
          const style = document.createElement('style'); style.textContent = pasteCSS; head.append(style);
          return {html:'<!DOCTYPE html>\n' + copy.outerHTML, figures};
        }
        const screen = document.createElement('style');
        screen.textContent = '@media screen { body { box-sizing:border-box; max-width:52rem; margin-inline:auto; padding:2rem clamp(1rem,4vw,3rem); } img,svg { max-width:100%; } }';
        head.append(screen);
        return '<!DOCTYPE html>\n' + copy.outerHTML;
        """#
}
