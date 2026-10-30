import CoreGraphics
import Foundation

/// What to print of a slide deck: every slide on its own page, or only one of them.
public struct SlidePrintRequest: Equatable, Sendable {
    /// The size of one slide in CSS pixels, by which the deck is found again in the copy being laid out.
    public var slideSize: CGSize
    public var count: Int
    /// The 0-based index of the only slide to print; nil prints them all.
    public var onlyIndex: Int?

    public init(slideSize: CGSize, count: Int, onlyIndex: Int? = nil) {
        self.slideSize = slideSize
        self.count = count
        self.onlyIndex = onlyIndex
    }

    public init(deck: SlideDeck, printsCurrentOnly: Bool) {
        self.init(
            slideSize: deck.size, count: deck.count, onlyIndex: printsCurrentOnly ? deck.currentIndex : nil)
    }
}

/// The scripts that measure slide decks on a page and lay them out one slide to a page. They run in the app's own
/// content world, so they work whether or not the page's JavaScript may run, and they only read the live page.
public enum SlideDeckScript {
    /// Defines the functions that look for slide decks:
    /// - `surimonoSlideCandidates()` finds the groups of sibling elements (by tag) that share one size and tells for
    ///   each member whether its size is fixed, from the declared `width`, `height` and `aspect-ratio` of the matching
    ///   style rules and the inline style. It walks the whole document and its style sheets, so it runs only when the
    ///   page's elements or styles may have changed.
    /// - `surimonoSlideMeasure(candidates)` measures where those members are now, as `SlideFacts` reads them; it is
    ///   cheap enough for every scroll.
    /// - `surimonoSlideGroups()` does both; `surimonoSlideFactsJSON(facts)` turns the facts into JSON.
    static let collector = #"""
        const surimonoSlideRendered = element => element.getClientRects().length > 0;
        // A hidden slide has no layout box; its computed size is what its rules declare.
        const surimonoSlideSize = element => {
          if (surimonoSlideRendered(element)) return [element.offsetWidth, element.offsetHeight];
          const style = getComputedStyle(element);
          const pixels = value => (/^[\d.]+px$/.test(value) ? parseFloat(value) : 0);
          return [pixels(style.width), pixels(style.height)];
        };
        const surimonoSlideCandidates = () => {
          if (!document.body) return [];
          // Replaced elements carry their own size, and a set of equal images or videos is not a deck.
          const skipped = new Set([
            'SCRIPT', 'STYLE', 'TEMPLATE', 'LINK', 'META', 'NOSCRIPT', 'IMG', 'PICTURE', 'VIDEO', 'AUDIO', 'IFRAME',
            'CANVAS', 'EMBED', 'OBJECT', 'SOURCE', 'TRACK', 'BR', 'HR', 'INPUT', 'SELECT', 'TEXTAREA', 'BUTTON',
          ]);
          const close = (a, b) => Math.abs(a - b) <= Math.max(1, b * 0.005);
          const found = [];
          for (const parent of [document.body, ...document.body.querySelectorAll('*')]) {
            if (parent.children.length < 2) continue;
            const byTag = new Map();
            for (const child of Array.from(parent.children)) {
              if (!(child instanceof HTMLElement) || skipped.has(child.tagName)) continue;
              const list = byTag.get(child.tagName) || [];
              list.push(child);
              byTag.set(child.tagName, list);
            }
            for (const elements of byTag.values()) {
              if (elements.length < 2) continue;
              const sizes = elements.map(surimonoSlideSize);
              const [width, height] = sizes[0];
              if (width < 1 || height < 1) continue;
              if (!sizes.every(([w, h]) => close(w, width) && close(h, height))) continue;
              found.push({ elements, area: width * height });
            }
          }
          if (found.length === 0) return [];
          found.sort((a, b) => b.area - a.area);
          found.length = Math.min(found.length, 40);

          let rules = null;
          const styleRules = () => {
            if (rules) return rules;
            rules = [];
            const applies = media => {
              const text = ((media && media.mediaText) || '').trim();
              if (!text) return true;
              try { return window.matchMedia(text).matches; } catch (_) { return true; }
            };
            const walk = list => {
              for (const rule of Array.from(list || [])) {
                if (rule.type === CSSRule.STYLE_RULE) {
                  rules.push(rule);
                  continue;
                }
                if (rule.media && !applies(rule.media)) continue;
                if (rule.type === CSSRule.SUPPORTS_RULE) {
                  try { if (!CSS.supports(rule.conditionText)) continue; } catch (_) { continue; }
                }
                if (rule.styleSheet) {
                  try { walk(rule.styleSheet.cssRules); } catch (_) {}
                }
                try { if (rule.cssRules) walk(rule.cssRules); } catch (_) {}
              }
            };
            for (const sheet of Array.from(document.styleSheets)) {
              if (sheet.disabled || !applies(sheet.media)) continue;
              // A style sheet from another origin cannot be read; its sizes count as not fixed.
              try { walk(sheet.cssRules); } catch (_) {}
            }
            return rules;
          };
          // Later rules win over earlier ones and important ones over the rest; specificity is not weighed.
          const declared = (element, property) => {
            let value = '';
            let important = false;
            for (const rule of styleRules()) {
              let matches = false;
              try { matches = element.matches(rule.selectorText); } catch (_) {}
              if (!matches) continue;
              const candidate = rule.style.getPropertyValue(property);
              if (!candidate) continue;
              const isImportant = rule.style.getPropertyPriority(property) === 'important';
              if (isImportant || !important) {
                value = candidate;
                important = important || isImportant;
              }
            }
            const inline = element.style.getPropertyValue(property);
            if (inline && (!important || element.style.getPropertyPriority(property) === 'important')) value = inline;
            const computed = getComputedStyle(element);
            return value.replace(/var\(\s*(--[\w-]+)[^)]*\)/g, (_, name) => computed.getPropertyValue(name)).trim();
          };
          const fluid = /%|vw|vh|vmin|vmax|auto|content|stretch|available|inherit|initial|unset|revert/i;
          const isFixed = value => value !== '' && !fluid.test(value);
          const fixedSize = element => {
            if (!isFixed(declared(element, 'width'))) return false;
            if (isFixed(declared(element, 'height'))) return true;
            const ratio = declared(element, 'aspect-ratio');
            return ratio !== '' && !/auto/i.test(ratio);
          };
          return found.map(group => ({ elements: group.elements, fixed: group.elements.map(fixedSize) }));
        };
        const surimonoSlideMeasure = candidates => {
          const viewportWidth = window.innerWidth;
          const viewportHeight = window.innerHeight;
          // The share of the box its clipping ancestors leave showing, and of that the share in the viewport. A
          // hidden element shows nothing.
          const shares = element => {
            if (!element.isConnected || !surimonoSlideRendered(element)) return [0, 0];
            const style = getComputedStyle(element);
            if (style.visibility === 'hidden' || parseFloat(style.opacity) < 0.01) return [0, 0];
            const box = element.getBoundingClientRect();
            if (box.width <= 0 || box.height <= 0) return [0, 0];
            let left = box.left;
            let top = box.top;
            let right = box.right;
            let bottom = box.bottom;
            for (let node = element.parentElement; node && node !== document.body; node = node.parentElement) {
              const nodeStyle = getComputedStyle(node);
              if (parseFloat(nodeStyle.opacity) < 0.01) return [0, 0];
              if (nodeStyle.overflowX === 'visible' && nodeStyle.overflowY === 'visible') continue;
              const clip = node.getBoundingClientRect();
              left = Math.max(left, clip.left);
              top = Math.max(top, clip.top);
              right = Math.min(right, clip.right);
              bottom = Math.min(bottom, clip.bottom);
            }
            const area = box.width * box.height;
            const unclipped = (Math.max(0, right - left) * Math.max(0, bottom - top)) / area;
            const visible =
              (Math.max(0, Math.min(right, viewportWidth) - Math.max(left, 0))
                * Math.max(0, Math.min(bottom, viewportHeight) - Math.max(top, 0))) / area;
            return [unclipped, visible];
          };
          const groups = candidates.map(candidate => ({
            elements: candidate.elements,
            members: candidate.elements.map((element, index) => {
              const [width, height] = surimonoSlideSize(element);
              const box = element.getBoundingClientRect();
              const [unclipped, visible] = shares(element);
              return {
                width, height, fixed: candidate.fixed[index], visible, unclipped,
                x: box.left, y: box.top, boxWidth: box.width, boxHeight: box.height,
              };
            }),
          }));
          return { viewportWidth, viewportHeight, groups };
        };
        const surimonoSlideGroups = () => surimonoSlideMeasure(surimonoSlideCandidates());
        const surimonoSlideFactsJSON = facts => JSON.stringify({
          viewportWidth: facts.viewportWidth, viewportHeight: facts.viewportHeight,
          groups: facts.groups.map(group => ({ members: group.members })),
        });
        """#

    /// A callAsyncJavaScript function body that returns the facts as JSON, which `SlideFacts(json:)` reads.
    public static let javaScript = collector + "\nreturn surimonoSlideFactsJSON(surimonoSlideGroups());"

    /// A user script that sends the facts as JSON to the message handler `messageName` once the page has loaded, and
    /// again whenever they change. A change of the page's elements, classes, inline styles or style sheets, or a
    /// resize that may switch its media queries, looks for the decks again; a scroll, a click or a key only measures
    /// the slides already found, which is all that turning a slide needs. Reports wait until the page has been quiet
    /// for a moment, but no longer than a little over half a second, and are dropped when nothing changed.
    public static func observerJavaScript(messageName: String) -> String {
        "(() => {\n" + collector + "\n"
            + """
            let candidates = null;
            let timer = null;
            let firstRequest = null;
            let last = null;
            let started = false;
            const report = () => {
              timer = null;
              firstRequest = null;
              let json;
              try {
                if (candidates === null) candidates = surimonoSlideCandidates();
                json = surimonoSlideFactsJSON(surimonoSlideMeasure(candidates));
              } catch (_) { return; }
              if (json === last) return;
              last = json;
              window.webkit.messageHandlers.\(messageName).postMessage(json);
            };
            const schedule = changesStyle => {
              if (changesStyle) candidates = null;
              if (!started) return;
              const now = performance.now();
              if (firstRequest === null) firstRequest = now;
              if (timer !== null) clearTimeout(timer);
              timer = setTimeout(report, now - firstRequest >= 600 ? 0 : 150);
            };
            // Decks set themselves up while loading; the second report catches one that does so a little later.
            const start = () => {
              if (started) return;
              started = true;
              report();
              setTimeout(() => schedule(true), 700);
            };
            if (document.readyState === 'complete') start(); else window.addEventListener('load', start);
            window.addEventListener('resize', () => schedule(true), { passive: true });
            // A style sheet that finishes loading changes the styles too.
            document.addEventListener('load', event => {
              if (event.target && event.target.tagName === 'LINK') schedule(true);
            }, true);
            for (const type of ['keyup', 'click', 'hashchange', 'transitionend', 'animationend', 'scroll']) {
              window.addEventListener(type, () => schedule(false), { capture: true, passive: true });
            }
            // Text that changes inside the page only moves things; elements, attributes and style text restyle it.
            const restyles = record => {
              if (record.type === 'attributes') return true;
              if (record.type === 'characterData') return record.target.parentNode?.nodeName === 'STYLE';
              const nodes = [...record.addedNodes, ...record.removedNodes];
              return record.target.nodeName === 'STYLE' || nodes.some(node => node.nodeType === Node.ELEMENT_NODE);
            };
            new MutationObserver(records => schedule(records.some(restyles))).observe(document.documentElement, {
              attributes: true, childList: true, characterData: true, subtree: true,
              attributeFilter: ['class', 'style', 'hidden', 'aria-hidden', 'aria-current', 'media', 'disabled'],
            });
            """ + "\n})();"
    }

    /// A preparation script for the copy being laid out, never the live page. It finds the deck again by the size
    /// and number of its slides, shows each printed slide whatever hid it (display, opacity, visibility, transforms
    /// and positions that decks use to show one slide at a time), scales each to fit the printable area and starts
    /// a page after each. Everything else on the page, such as the deck's buttons and its backdrop, is hidden.
    /// It returns nothing.
    /// - Parameter printableSize: The printable area of a logical page, in CSS pixels.
    public static func printJavaScript(_ request: SlidePrintRequest, printableSize: CGSize) -> String {
        let width = Double(request.slideSize.width)
        let height = Double(request.slideSize.height)
        // WebKit lays a page out for print 1.25 times as large as the printable area (its minimum shrink factor)
        // and shrinks it onto the paper; a little room is left so that rounding never spills a slide over a page.
        let printLayout = 1.25
        let scale =
            min(Double(printableSize.width) / width, Double(printableSize.height) / height) * printLayout * 0.98
        return "{\n" + collector + "\n"
            + """
            const close = (a, b) => Math.abs(a - b) <= Math.max(1, b * 0.005);
            const deck = surimonoSlideGroups().groups.find(group =>
              group.members.length === \(request.count)
              && close(group.members[0].width, \(width)) && close(group.members[0].height, \(height)));
            if (deck) {
              const only = \(request.onlyIndex ?? -1);
              const slides = deck.elements;
              const set = (element, property, value) => element.style.setProperty(property, value, 'important');
              // The slide on show tells how a shown slide is laid out, such as flex or grid.
              const shown = slides.find(slide => slide.getClientRects().length > 0);
              let display = shown ? getComputedStyle(shown).display : 'block';
              display = { none: 'block', contents: 'block', inline: 'block', 'inline-block': 'block',
                'inline-flex': 'flex', 'inline-grid': 'grid' }[display] || display;
              const printed = slides.filter((_, index) => only < 0 || index === only);
              for (const slide of slides) {
                if (!printed.includes(slide)) set(slide, 'display', 'none');
              }
              for (const slide of printed) {
                for (const [property, value] of [
                  ['display', display], ['opacity', '1'], ['visibility', 'visible'], ['transform', 'none'],
                  ['translate', 'none'], ['scale', 'none'], ['rotate', 'none'], ['position', 'relative'],
                  ['left', 'auto'], ['top', 'auto'], ['right', 'auto'], ['bottom', 'auto'], ['margin', '0'],
                  ['float', 'none'], ['flex', 'none'], ['width', '\(width)px'], ['height', '\(height)px'],
                  ['max-width', 'none'], ['max-height', 'none'], ['min-width', '0'], ['min-height', '0'],
                  ['overflow', 'hidden'], ['clip-path', 'none'], ['content-visibility', 'visible'],
                  ['zoom', '\(scale)'], ['break-inside', 'avoid'], ['page-break-inside', 'avoid'],
                  ['break-after', 'page'], ['page-break-after', 'always'],
                ]) set(slide, property, value);
              }
              const last = printed[printed.length - 1];
              if (last) {
                set(last, 'break-after', 'auto');
                set(last, 'page-break-after', 'auto');
              }
              const parent = slides[0].parentElement;
              for (const child of Array.from(parent.children)) {
                if (!slides.includes(child)) set(child, 'display', 'none');
              }
              set(parent, 'display', 'block');
              const kept = new Set(['HEAD', 'SCRIPT', 'STYLE', 'LINK', 'META', 'TITLE', 'TEMPLATE']);
              for (let node = parent; node && node !== document.documentElement; node = node.parentElement) {
                for (const [property, value] of [
                  ['transform', 'none'], ['translate', 'none'], ['scale', 'none'], ['rotate', 'none'],
                  ['overflow', 'visible'], ['position', 'static'], ['width', 'auto'], ['height', 'auto'],
                  ['min-width', '0'], ['min-height', '0'], ['max-width', 'none'], ['max-height', 'none'],
                  ['margin', '0'], ['padding', '0'], ['border', '0'], ['zoom', '1'], ['background', 'transparent'],
                ]) set(node, property, value);
                if (node !== parent && getComputedStyle(node).display !== 'block') set(node, 'display', 'block');
                for (const sibling of Array.from(node.parentElement ? node.parentElement.children : [])) {
                  if (sibling !== node && !kept.has(sibling.tagName)) set(sibling, 'display', 'none');
                }
              }
              set(document.documentElement, 'margin', '0');
              set(document.documentElement, 'padding', '0');
              // The page around the slides is the deck's screen backdrop, which would only spend ink on paper.
              set(document.documentElement, 'background', 'transparent');
            }
            """ + "\n}"
    }
}
