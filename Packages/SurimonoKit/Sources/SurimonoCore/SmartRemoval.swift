import Foundation

public struct SmartRemovalCandidate: Codable, Equatable, Sendable, Identifiable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case cookieBanner, stickyHeader, advertisement, socialButtons, newsletter, relatedLinks, popup
    }

    public let id: String
    public let category: Category
    public let excerpt: String
    public let reason: String

    public init(id: String, category: Category, excerpt: String, reason: String) {
        self.id = id
        self.category = category
        self.excerpt = excerpt
        self.reason = reason
    }
}

public struct SmartRemovalRequest: Codable, Equatable, Hashable, Sendable {
    public var keptIDs: [String]
    /// Outline candidates instead of removing them; kept candidates get a lighter outline.
    public var highlightsCandidates: Bool

    public init(keptIDs: [String] = [], highlightsCandidates: Bool = false) {
        self.keptIDs = keptIDs
        self.highlightsCandidates = highlightsCandidates
    }
}

public enum SmartRemovalScript {
    public static func candidates(fromJSON json: String) -> [SmartRemovalCandidate] {
        (try? JSONDecoder().decode([SmartRemovalCandidate].self, from: Data(json.utf8))) ?? []
    }

    /// A callAsyncJavaScript function body that works entirely on the current DOM and returns JSON.
    public static func javaScript(for request: SmartRemovalRequest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(request) else { return "return '[]';" }
        // Also safe if a caller embeds the body in HTML rather than using callAsyncJavaScript.
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: #"\u003c"#)
            .replacingOccurrences(of: "\u{2028}", with: #"\u2028"#)
            .replacingOccurrences(of: "\u{2029}", with: #"\u2029"#)
        return "const request = \(json);\n" + #"""
            const body = document.body;
            if (!body) return '[]';
            const clean = value => (value || '').replace(/\s+/g, ' ').trim();
            const text = element => clean(element.innerText);
            const clip = (value, count) => Array.from(value).slice(0, count).join('');
            const tokens = value => clean(value).replace(/([a-z])([A-Z])/g, '$1 $2')
              .toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
            const elements = Array.from(body.querySelectorAll('*'));
            const visible = element => {
              const style = getComputedStyle(element);
              return style.display !== 'none' && style.visibility !== 'hidden' && element.getClientRects().length > 0;
            };
            const attributesOf = element => Array.from(element.attributes).filter(attribute =>
              ['id', 'class', 'aria-label', 'role'].includes(attribute.name) || attribute.name.startsWith('data-'));
            const signalsOf = element => new Set(attributesOf(element).flatMap(attribute => tokens(
              attribute.name.startsWith('data-') ? attribute.name : attribute.value)));
            const related = signals => ['related', 'recommend', 'recommended', 'popular', 'ranking']
              .some(word => signals.has(word)) || (signals.has('read') && signals.has('next'));
            const auxiliary = element => {
              for (let node = element; node && node !== body; node = node.parentElement) {
                if (node.matches('aside, nav') || related(signalsOf(node))) return true;
              }
              return false;
            };
            const punctuation = value => (value.match(/[.!?。、]/g) || []).length;
            const scores = new Map();
            for (const paragraph of body.querySelectorAll('p')) {
              if (!visible(paragraph) || auxiliary(paragraph)) continue;
              const value = text(paragraph);
              const score = value.length + punctuation(value) * 20;
              for (let parent = paragraph.parentElement; parent && parent !== body; parent = parent.parentElement) {
                if (parent.matches('div, section, article, main, [role="main"]')) {
                  scores.set(parent, (scores.get(parent) || 0) + score);
                }
              }
            }
            const regions = selector => elements.filter(element =>
              element.matches(selector) && visible(element) && !auxiliary(element));
            let regionsToRank = regions('main, [role="main"]');
            if (!regionsToRank.length) regionsToRank = regions('article');
            const explicit = regionsToRank.length > 0;
            if (!explicit) regionsToRank = elements.filter(element => scores.has(element));
            let main = null;
            let highest = -1;
            // Related cards are not main regions; only the strongest prose region is protected.
            for (const element of regionsToRank) {
              const score = scores.get(element) || 0;
              // For the paragraph fallback, prefer a deeper block over an equally scored wrapper.
              if (score > highest || (!explicit && score === highest)) { highest = score; main = element; }
            }
            const looksLikeProse = element => {
              const paragraphs = Array.from(element.querySelectorAll('p')).filter(visible);
              const prose = paragraphs.map(text).join(' ');
              const sentences = punctuation(prose);
              const heading = element.querySelector('h1, h2, h3, h4, h5, h6');
              const value = text(element);
              return (heading && prose.length >= 80 && sentences >= 1)
                || (prose.length >= 160 && sentences >= 2) || prose.length >= 320
                || (value.length >= 240 && punctuation(value) >= 2);
            };
            const identifier = element => {
              if (element.id) {
                const selector = '#' + CSS.escape(element.id);
                if (document.querySelectorAll(selector).length === 1) return selector;
              }
              const path = [];
              for (let node = element; node && node !== body; node = node.parentElement) {
                const tag = node.localName;
                const siblings = Array.from(node.parentElement.children).filter(sibling => sibling.localName === tag);
                path.unshift(CSS.escape(tag) + ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')');
              }
              return 'body > ' + path.join(' > ');
            };
            const adHost = element => {
              if (element.localName !== 'iframe') return null;
              try {
                const host = new URL(element.getAttribute('src') || '', document.baseURI).hostname.toLowerCase();
                const domains = ['doubleclick.net', 'googlesyndication.com', 'amazon-adsystem.com',
                  'taboola.com', 'outbrain.com', 'criteo.com', 'criteo.net'];
                return domains.some(domain => host === domain || host.endsWith('.' + domain))
                  || /(^|\.)adservice\.google\.[a-z.]+$/.test(host) ? host : null;
              } catch (_) { return null; }
            };
            const classify = element => {
              const blocks = 'div, section, article, aside, nav, ul, ol, form, iframe, ins, header, footer, dialog';
              if (!element.matches(blocks)) return null;
              if (!visible(element) || (main && (element === main || element.contains(main)))) return null;
              const inside = main && main.contains(element);
              // Topic names and even ad-like attributes cannot justify removing article prose.
              if (inside && looksLikeProse(element)) return null;
              const attributes = attributesOf(element);
              const signals = signalsOf(element);
              const has = (...words) => words.some(word => signals.has(word));
              const evidence = clip(attributes.map(attribute => attribute.name + '="' + attribute.value + '"').join(' · '), 140);
              const style = getComputedStyle(element);
              const positioned = ['fixed', 'sticky'].includes(style.position);
              const words = text(element);
              const links = Array.from(element.querySelectorAll('a'));
              const hit = (category, reason) => ({category, reason: reason || evidence});
              if (!inside && (has('cookie', 'cookies', 'consent', 'gdpr')
                || (positioned && /\b(cookies?|consent|gdpr)\b|クッキー|Cookieの同意/i.test(words)))) {
                return hit('cookieBanner', [evidence, 'position: ' + style.position].filter(Boolean).join(' · '));
              }
              const host = adHost(element) || Array.from(element.querySelectorAll('iframe')).map(adHost).find(Boolean);
              const adTopic = has('ad', 'ads', 'advert', 'advertisement', 'advertising', 'sponsor', 'sponsored', 'promo');
              const adSlot = has('adsbygoogle') || attributes.some(attribute =>
                attribute.name.startsWith('data-ad-')
                || (['id', 'class'].includes(attribute.name) && /(?:^|\s)ad[-_]slot(?:$|[-_\s])/i.test(attribute.value)))
                || /^(advertisement|advertising|sponsored)(\s+content)?$/i
                  .test(clean(element.getAttribute('aria-label')));
              const smallWidget = words.length <= 80 && !element.querySelector('h1, h2, h3, h4, h5, h6, p');
              if ((!inside && (host || adTopic || adSlot)) || (inside && (host || adSlot || (adTopic && smallWidget)))) {
                return hit('advertisement', host ? 'iframe host: ' + host : evidence);
              }
              if (has('share', 'social', 'sns') && element.querySelector('a, button')) return hit('socialButtons');
              if ((element.matches('form') || has('newsletter', 'subscribe', 'signup'))
                && element.querySelector('input[type="email"]')) return hit('newsletter', evidence || 'form with email input');
              if (related(signals)) {
                if (links.length >= 2) return hit('relatedLinks');
              }
              if (!inside) {
                if (has('modal', 'popup', 'overlay', 'dialog') || element.getAttribute('aria-modal') === 'true') {
                  return hit('popup', evidence || 'aria-modal="true"');
                }
                const rect = element.getBoundingClientRect();
                if (positioned && rect.top <= 100 && rect.bottom > 0 && rect.height <= 250
                  && (element.matches('header, [role="banner"]') || element.querySelector('nav'))) {
                  return hit('stickyHeader', [evidence, 'position: ' + style.position].filter(Boolean).join(' · '));
                }
                const linkLength = links.reduce((sum, link) => sum + text(link).length, 0);
                const density = words.length ? Math.min(1, linkLength / words.length) : 0;
                if (links.length >= 3 && density >= 0.75) return hit('relatedLinks', 'link density ' + density.toFixed(2));
              }
              return null;
            };
            const matches = new Map();
            for (const element of elements) {
              const match = classify(element);
              if (match) matches.set(element, match);
            }
            const selected = [];
            for (const [element, match] of matches) {
              let nested = false;
              for (let parent = element.parentElement; parent && parent !== body; parent = parent.parentElement) {
                if (matches.has(parent)) { nested = true; break; }
              }
              if (!nested) selected.push({element, candidate: {
                id: identifier(element), category: match.category,
                excerpt: clip(text(element) || clean(element.getAttribute('aria-label')), 40).trim(), reason: match.reason
              }});
            }
            // Complete detection before mutating the DOM so kept IDs cannot change candidate identity or order.
            const kept = new Set(request.keptIDs);
            for (const {element, candidate} of selected) {
              const keep = kept.has(candidate.id);
              if (request.highlightsCandidates) {
                element.style.setProperty('outline', keep ? '1px solid #94a3b8' : '2px dashed #b45309', 'important');
                element.style.setProperty('outline-offset', '-2px', 'important');
                element.style.setProperty('-webkit-print-color-adjust', 'exact', 'important');
                element.style.setProperty('print-color-adjust', 'exact', 'important');
                if (getComputedStyle(element).position === 'static') element.style.position = 'relative';
                const label = document.createElement('span');
                label.textContent = candidate.category + (keep ? ' (kept)' : '');
                label.style.cssText = 'position:absolute;top:0;right:0;font:9px sans-serif;line-height:12px;'
                  + 'background:#fff;color:#555;pointer-events:none;z-index:2147483647;';
                if (element.localName === 'iframe') {
                  // An iframe does not render child nodes; place its review label in the containing block.
                  const parent = element.parentElement;
                  if (getComputedStyle(parent).position === 'static') parent.style.position = 'relative';
                  label.style.top = element.offsetTop + 'px';
                  label.style.left = element.offsetLeft + 'px';
                  label.style.right = 'auto';
                  parent.appendChild(label);
                } else {
                  element.appendChild(label);
                }
              } else if (!keep) {
                element.style.setProperty('display', 'none', 'important');
              }
            }
            return JSON.stringify(selected.map(item => item.candidate));
            """#
    }
}
