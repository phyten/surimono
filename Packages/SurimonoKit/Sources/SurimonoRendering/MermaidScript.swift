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

    static let probe = "return document.querySelector('.mermaid-block > .mermaid-source') ? 'yes' : 'no';"

    private static var offlineRules: WKContentRuleList?

    static func preventResourceLoads(in webView: WKWebView) async throws {
        if offlineRules == nil {
            offlineRules = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "surimono-mermaid-offline",
                encodedContentRuleList: #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#)
        }
        if let offlineRules { webView.configuration.userContentController.add(offlineRules) }
    }

    static let fallback = """
        for (const source of document.querySelectorAll('.mermaid-block > .mermaid-source')) {
          source.parentElement.classList.add('mermaid-error');
        }
        """

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
        let stopped = false;
        for (const [index, source] of sources.entries()) {
          const block = source.parentElement;
          const remaining = deadline - performance.now();
          if (stopped || remaining <= 0) continue;
          // Over the limit, the library draws a placeholder diagram instead of throwing; keep the source instead.
          if (source.textContent.length > \(maxTextSize)) continue;
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
              }, Math.min(2000, remaining)); })
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
            block.replaceChildren(document.importNode(svg, true));
            block.classList.remove('mermaid-error');
          } catch (_) {
            // A bad diagram keeps its escaped source; later diagrams may still be valid.
          } finally {
            clearTimeout(timer);
            staging.remove();
          }
        }
        """
    }
}
