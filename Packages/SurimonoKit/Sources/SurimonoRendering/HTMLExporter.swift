import Foundation
import SurimonoCore

@MainActor
public enum HTMLExporter {
    public static func html(
        source: DocumentSource, settings: RenderSettings, title: String
    ) async throws -> String {
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
            exportHTMLTitle: title)
        guard let exported = result.exportedHTML else { throw WebPaginator.PaginationError.emptyDocument }
        return exported
    }

    // Only bytes WebKit accepted as an image may leave the app. An img pointing at an arbitrary local text file
    // must fail rather than embedding that file's bytes in an apparently harmless data URI.
    static let imageResourceScript = #"""
        return Array.from(document.images).map(image => {
          const url = image.currentSrc || image.src;
          if (!/^(https?:|data:)/i.test(url) && (!image.complete || !image.naturalWidth))
            throw new Error('A local image could not be embedded.');
          return url;
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
        const screen = document.createElement('style');
        screen.textContent = '@media screen { body { box-sizing:border-box; max-width:52rem; margin-inline:auto; padding:2rem clamp(1rem,4vw,3rem); } img,svg { max-width:100%; } }';
        head.append(screen);
        return '<!DOCTYPE html>\n' + copy.outerHTML;
        """#
}
