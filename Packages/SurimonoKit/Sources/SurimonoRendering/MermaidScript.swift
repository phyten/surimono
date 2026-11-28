import Foundation
import WebKit

@MainActor
enum MermaidScript {
    // Cache the bytes in the host, but evaluate them only once in each document that actually has diagrams.
    static let library = Bundle.module.url(forResource: "mermaid.min", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// The preparation runs as the body of an async function, where the bundle's top-level `var` would stay local
    /// while its last line reads the namespace from `globalThis`; binding both to one object keeps the file unchanged.
    static func loading(_ library: String) -> String {
        """
        "use strict";
        var __esbuild_esm_mermaid_nm = globalThis.__esbuild_esm_mermaid_nm = globalThis.__esbuild_esm_mermaid_nm || {};
        \(library)
        ;return typeof globalThis.mermaid?.render;
        """
    }

    static let probe = "return String(document.querySelectorAll('.mermaid-block > .mermaid-source').length);"

    /// Compiled lists by the images they let through; a document compiles one only for a new set of images. All share
    /// one stored identifier, so the store keeps a single file, and a web view holds only the latest of them.
    private static var offlineRules: [String: WKContentRuleList] = [:]

    /// Blocks every load from now on, except the images the document has already shown. Later preparation (figure
    /// placement, paragraph composition, the flow layout) moves or copies those images, and each copy loads its
    /// image again; blocking them too left LaTeX figures blank once a TikZ picture had been drawn. Engines still
    /// cannot fetch anything the document did not already show.
    static func preventResourceLoads(in webView: WKWebView) async throws {
        let shown =
            (try? await webView.evaluateForPrinting(shownImagesScript, until: .now + .seconds(15))) as? [String] ?? []
        let rules = try await offlineRules(keeping: shown)
        webView.configuration.userContentController.add(rules)
    }

    static let shownImagesScript = """
        const urls = new Set();
        for (const image of document.images) {
          const url = image.currentSrc || '';
          if (image.complete && image.naturalWidth && /^[\\x21-\\x7e]{1,2048}$/.test(url)) urls.add(url);
        }
        return Array.from(urls).sort().slice(0, 1000);
        """

    static func offlineRules(keeping images: [String]) async throws -> WKContentRuleList {
        let key = images.joined(separator: "\n")
        if let cached = offlineRules[key] { return cached }
        var rules: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
        for url in ["^data:"] + images.map({ "^" + escapedFilter($0) + "$" }) {
            rules.append([
                "trigger": ["url-filter": url, "resource-type": ["image"]],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        let list: WKContentRuleList
        do {
            list = try await compile(encoded, identifier: "surimono-offline")
        } catch {
            // An address WebKit's filter grammar refuses must not let the engines go online: block everything.
            list = try await compile(
                #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#, identifier: "surimono-offline")
        }
        if offlineRules.count >= 16 { offlineRules.removeAll() }
        offlineRules[key] = list
        return list
    }

    private static func compile(_ encoded: String, identifier: String) async throws -> WKContentRuleList {
        try await WebKitReply<WKContentRuleList>.wait(until: .now + .seconds(15)) { reply in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: encoded
            ) { list, error in
                if let list {
                    reply(.success(list))
                } else {
                    reply(.failure(error ?? WebPaginator.PaginationError.printFailed))
                }
            }
        }
    }

    /// A URL as a literal in WebKit's content rule filter, a subset of JavaScript regular expressions.
    static func escapedFilter(_ url: String) -> String {
        var escaped = ""
        for character in url {
            if "\\^$.|?*+()[]{}".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    static let fallback = """
        for (const source of document.querySelectorAll('.mermaid-block > .mermaid-source')) {
          source.parentElement.classList.add('mermaid-error');
        }
        """

    static func budgetMilliseconds(count: Int) -> Int {
        min(60_000, 10_000 + min(167, max(0, count)) * 300)
    }

    static let maxTextSize = 50000

    static func rendering(budgetMilliseconds: Int) -> String {
        """
        \(fallback)
        const sources = Array.from(document.querySelectorAll('.mermaid-block > .mermaid-source'));
        const deadline = performance.now() + \(budgetMilliseconds);
        const fontFamily = getComputedStyle(document.body).fontFamily;
        if (typeof mermaid === 'undefined') return;
        // Lock configuration from directives/front matter too: diagrams cannot opt into HTML, CSS or web fonts.
        mermaid.initialize({
          startOnLoad: false, theme: 'neutral', securityLevel: 'strict', fontFamily,
          htmlLabels: false, flowchart: {htmlLabels: false}, suppressErrorRendering: true,
          deterministicIds: true, maxTextSize: \(maxTextSize), maxEdges: 500,
          secure: [...Object.keys(mermaid.mermaidAPI.defaultConfig), 'htmlLabels', 'themeCSS', 'fontFamily', 'flowchart']
        });
        for (const source of sources) source.parentElement.classList.add('mermaid-timeout');
        let stopped = false;
        for (const [index, source] of sources.entries()) {
          const block = source.parentElement;
          const remaining = deadline - performance.now();
          if (stopped || remaining <= 0) continue;
          // Over the limit, the library draws a placeholder diagram instead of throwing; keep the source instead.
          if (source.textContent.length > \(maxTextSize)) {
            block.classList.remove('mermaid-timeout');
            continue;
          }
          const staging = document.createElement('div');
          // Layout needs a connected element; keep unfinished work out of the printed flow.
          staging.style.cssText = 'position:absolute;left:-100000px;top:0;visibility:hidden';
          document.body.appendChild(staging);
          let timer;
          try {
            const result = await Promise.race([
              mermaid.render('surimono-mermaid-' + index, source.textContent, staging),
              new Promise((_, reject) => { timer = setTimeout(() => {
                stopped = true;
                reject(new Error('timeout'));
              }, remaining); })
            ]);
            const parsed = new DOMParser().parseFromString(result.svg, 'image/svg+xml');
            const svg = parsed.documentElement;
            if (svg.localName !== 'svg' || parsed.querySelector('parsererror')) throw new Error('svg');
            // Keep the result static and local, even for diagram types that accept image or link syntax.
            // A diagram whose labels need HTML (math labels use foreignObject even without htmlLabels) or images
            // would lose content once those parts are removed, so it fails as a whole and keeps its source.
            if (svg.querySelector('script,foreignObject,image')) throw new Error('unsupported');
            for (const node of svg.querySelectorAll('a')) node.replaceWith(...node.childNodes);
            const width = svg.viewBox.baseVal.width;
            if (width > 0) svg.style.width = width + 'px';
            svg.style.maxWidth = '100%';
            svg.style.height = 'auto';
            const rendered = document.importNode(svg, true);
            block.replaceChildren(rendered);
            globalThis.surimonoRenderedDiagrams?.add(rendered);
            block.classList.remove('mermaid-error', 'mermaid-timeout');
          } catch (_) {
            // Syntax failures keep their individual diagnostics.
            if (!stopped) block.classList.remove('mermaid-timeout');
          } finally {
            clearTimeout(timer);
            staging.remove();
          }
        }
        """
    }
}
