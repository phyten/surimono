/// Prepares a web page for paper before the cleanup preset runs. On paper, WebKit repeats fixed elements on every
/// page over the text, and a section as tall as the viewport fills a page of its own. A document's own print rules
/// already say what it wants on paper, so rules inside `@media print` and `@page` stay as written.
public enum PaperCleanupScript {
    /// Runs `script`, then the cleanup, and returns the result of `script`. Smart Removal recognises sticky headers
    /// and banners by their position, so it has to see the page before the cleanup makes them static.
    public static func following(_ script: String) -> String {
        "const surimonoPreparationResult = await (async () => {\n" + script + "\n})();\n" + javaScript
            + "\nreturn surimonoPreparationResult;"
    }

    /// A callAsyncJavaScript function body. It returns nothing, so the scripts after it still run.
    public static let javaScript = #"""
        {
          const fullHeight = /(^|[^0-9.])100(\.0+)?[dsl]?vh\b/i;
          const fix = style => {
            const position = style.getPropertyValue('position').trim().toLowerCase();
            if (position === 'fixed' || position === 'sticky' || position === '-webkit-sticky') {
              style.setProperty('position', 'static', style.getPropertyPriority('position'));
            }
            for (const property of ['height', 'min-height']) {
              if (fullHeight.test(style.getPropertyValue(property))) {
                style.setProperty(property, 'auto', style.getPropertyPriority(property));
              }
            }
          };
          const walk = rules => {
            for (const rule of Array.from(rules || [])) {
              if (rule.media && /\bprint\b/i.test(rule.media.mediaText || '')) continue;
              if (rule.type === CSSRule.PAGE_RULE) continue;
              if (rule.type === CSSRule.STYLE_RULE && rule.style) fix(rule.style);
              if (rule.styleSheet) {
                try { walk(rule.styleSheet.cssRules); } catch (_) {}
              }
              try { if (rule.cssRules) walk(rule.cssRules); } catch (_) {}
            }
          };
          for (const sheet of Array.from(document.styleSheets)) {
            if (sheet.media && /\bprint\b/i.test(sheet.media.mediaText || '')) continue;
            // A style sheet from another origin cannot be read; it stays as it is.
            try { walk(sheet.cssRules); } catch (_) {}
          }
          for (const element of Array.from(document.querySelectorAll('[style]'))) fix(element.style);
        }
        """#
}
