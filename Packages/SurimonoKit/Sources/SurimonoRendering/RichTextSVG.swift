import AppKit
import WebKit

/// Snapshot the prepared DOM so data-URL math fonts are drawn by the same engine that loaded them.
/// Loading serialized SVG into an Image/canvas can silently substitute those fonts in WebKit.
@MainActor
enum RichTextSVG {
    static func prepare(in webView: WKWebView, figureLabel: String) async throws -> String {
        let world = WKContentWorld.world(name: "surimono")
        let count =
            try await webView.callAsyncJavaScript(
                """
                await Promise.race([document.fonts.ready, new Promise(r => setTimeout(r, 5000))]);
                return document.querySelectorAll('svg:not(svg svg)').length;
                """,
                arguments: [:], in: nil, contentWorld: world) as? Int ?? 0
        for _ in 0..<count {
            try Task.checkCancellation()
            let dimensions =
                try await webView.callAsyncJavaScript(
                    stageScript, arguments: ["figureLabel": figureLabel], in: nil, contentWorld: world) as? [Double]
                ?? []
            var png = ""
            if dimensions.count == 2, dimensions.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 4096 }) {
                let configuration = WKSnapshotConfiguration()
                configuration.rect = CGRect(x: 0, y: 0, width: dimensions[0], height: dimensions[1])
                configuration.snapshotWidth = NSNumber(value: dimensions[0] * 2)
                do {
                    guard let image = await snapshot(in: webView, configuration: configuration) else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                        let context = CGContext(
                            data: nil, width: Int(ceil(dimensions[0] * 2)), height: Int(ceil(dimensions[1] * 2)),
                            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    {
                        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
                        if let bitmap = context.makeImage(),
                            let bytes = NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:])
                        {
                            png = "data:image/png;base64," + bytes.base64EncodedString()
                        }
                    }
                } catch {
                    // A failed snapshot must degrade to a label, never raw SVG text in AppKit's HTML importer.
                    try Task.checkCancellation()
                }
            }
            _ = try await webView.callAsyncJavaScript(
                replacementScript, arguments: ["png": png], in: nil, contentWorld: world)
        }
        return try await webView.callAsyncJavaScript(
            plainTextScript, arguments: [:], in: nil, contentWorld: world) as? String ?? ""
    }

    // WebKit callbacks can be lost when its process exits. A bounded continuation also allows alt fallback.
    private final class SnapshotRequest {
        var continuation: CheckedContinuation<NSImage?, Never>?

        func finish(_ image: NSImage?) {
            continuation?.resume(returning: image)
            continuation = nil
        }
    }

    private static func snapshot(in webView: WKWebView, configuration: WKSnapshotConfiguration) async -> NSImage? {
        let request = SnapshotRequest()
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            request.finish(nil)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            request.continuation = continuation
            webView.takeSnapshot(with: configuration) { image, error in
                request.finish(error == nil ? image : nil)
            }
        }
    }

    private static let stageScript = #"""
        const svg = document.querySelector('svg');
        const rect = svg.getBoundingClientRect();
        const alt = svg.closest('.math') ? (svg.getAttribute('aria-label') || figureLabel) : figureLabel;
        const clone = svg.cloneNode(true);
        const originals = [svg, ...svg.querySelectorAll('*')];
        const copies = [clone, ...clone.querySelectorAll('*')];
        originals.forEach((node, i) => {
          const style = getComputedStyle(node);
          for (const key of style) copies[i].style.setProperty(key, style.getPropertyValue(key));
        });
        clone.style.width = rect.width + 'px'; clone.style.height = rect.height + 'px';
        clone.style.margin = '0'; clone.style.position = 'static'; clone.style.transform = 'none';
        clone.style.display = 'block';
        const stage = document.createElement('div');
        stage.style.cssText = 'all:initial!important;display:block!important;position:fixed!important;' +
          'left:0!important;top:0!important;margin:0!important;' +
          'padding:2px!important;border:0!important;background:white!important;z-index:2147483647!important;';
        stage.append(clone); document.body.append(stage);
        globalThis.surimonoRaster = {svg, stage, alt, width:rect.width, height:rect.height,
          alignment:getComputedStyle(svg).verticalAlign};
        await Promise.race([new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))),
          new Promise(resolve => setTimeout(resolve, 250))]);
        return [rect.width + 4, rect.height + 4];
        """#

    private static let replacementScript = #"""
        const {svg, stage, alt, width, height, alignment} = globalThis.surimonoRaster;
        stage.remove();
        if (png) {
          const image = document.createElement('img');
          image.src = png; image.alt = alt;
          image.width = Math.ceil(width + 4); image.height = Math.ceil(height + 4);
          image.style.cssText = `width:${width + 4}px;height:${height + 4}px;vertical-align:${alignment};margin:-2px;`;
          svg.replaceWith(image);
        } else { svg.replaceWith(document.createTextNode(alt)); }
        delete globalThis.surimonoRaster;
        """#

    private static let plainTextScript = #"""
        document.querySelectorAll('img').forEach(node => {
          if (/^(https?:)?\/\//i.test(node.currentSrc || node.src)) node.replaceWith(document.createTextNode(node.alt || ''));
        });
        document.querySelectorAll('style').forEach(node => {
          node.textContent = node.textContent.replace(/url\(\s*['"]?(?:https?:)?\/\/[^)]*\)/gi, 'none');
        });
        document.querySelectorAll('[style]').forEach(node => {
          node.setAttribute('style', node.getAttribute('style').replace(/url\(\s*['"]?(?:https?:)?\/\/[^)]*\)/gi, 'none'));
        });
        const copy = document.body.cloneNode(true);
        copy.querySelectorAll('style,script,template').forEach(node => node.remove());
        copy.querySelectorAll('img').forEach(node => node.replaceWith(document.createTextNode(node.alt || '')));
        copy.querySelectorAll('br').forEach(node => node.replaceWith(document.createTextNode('\n')));
        copy.querySelectorAll('p,div,h1,h2,h3,h4,h5,h6,li,tr,pre,blockquote').forEach(node => node.append('\n'));
        copy.querySelectorAll('td,th').forEach(node => node.append('\t'));
        return copy.textContent.replace(/\n[ \t]*\n(?:[ \t]*\n)+/g, '\n\n').trim();
        """#
}
