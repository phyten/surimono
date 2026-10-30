import Foundation

/// A copy of a live web page's current state, as the snapshot script returns it.
public struct HTMLSnapshot: Equatable, Sendable {
    /// The document's HTML with its doctype.
    public var html: String
    /// The `<details>` closed on the live page. They print closed unless the reader asks to open them.
    public var closedDetailsCount: Int

    public init(html: String, closedDetailsCount: Int = 0) {
        self.html = html
        self.closedDetailsCount = closedDetailsCount
    }

    private struct Result: Decodable {
        let html: String
        let closedDetails: Int
    }

    /// Reads the snapshot script's result; nil for anything else.
    public init?(scriptResult json: String) {
        guard let result = try? JSONDecoder().decode(Result.self, from: Data(json.utf8)) else { return nil }
        self.init(html: result.html, closedDetailsCount: max(result.closedDetails, 0))
    }
}

/// Captures the current state of a live web page as HTML, so that paper and printing show what the reader sees:
/// entered values, opened details, chosen tabs, drawn canvases and animations at their end.
public enum HTMLSnapshotScript {
    /// A callAsyncJavaScript function body that returns, as JSON, the document's HTML with its doctype (`html`) and
    /// the number of closed `<details>` (`closedDetails`). `HTMLSnapshot(scriptResult:)` reads it.
    ///
    /// Everything is written to a copy of the document, matched to the live elements by their order: entered values
    /// become attributes, canvases become images, and each animated element keeps the state it reached, because the
    /// copy is laid out again without scripts, where CSS animations would start over. The live page is left as it
    /// was, apart from finite animations jumping to their end; endless ones pause only while they are read.
    public static let javaScript = #"""
        const frozen = new Map();
        const paused = [];
        if (document.getAnimations) {
          for (const animation of document.getAnimations()) {
            try {
              const effect = animation.effect;
              const timing = effect && effect.getComputedTiming();
              if (timing && Number.isFinite(timing.endTime)) {
                animation.finish();
              } else if (animation.playState === 'running') {
                animation.pause();
                paused.push(animation);
              }
              const target = effect && effect.target;
              if (!target || effect.pseudoElement || !effect.getKeyframes) continue;
              const properties = frozen.get(target) || new Set();
              for (const keyframe of effect.getKeyframes()) {
                for (const name of Object.keys(keyframe)) {
                  if (!['offset', 'computedOffset', 'easing', 'composite'].includes(name)) properties.add(name);
                }
              }
              frozen.set(target, properties);
            } catch (_) {}
          }
        }
        const frozenValues = new Map();
        for (const [element, properties] of frozen) {
          const computed = getComputedStyle(element);
          const values = [];
          for (const name of properties) {
            const property = name === 'cssFloat' ? 'float' : name.replace(/[A-Z]/g, c => '-' + c.toLowerCase());
            const value = computed.getPropertyValue(property);
            if (value) values.push([property, value]);
          }
          frozenValues.set(element, values);
        }

        const live = Array.from(document.documentElement.querySelectorAll('*'));
        const copy = document.documentElement.cloneNode(true);
        for (const animation of paused) {
          try { animation.play(); } catch (_) {}
        }
        const copied = Array.from(copy.querySelectorAll('*'));
        const positions = new Map(live.map((element, index) => [element, index]));
        const twin = element => copied[positions.get(element)];

        for (const input of live.filter(element => element.tagName === 'INPUT')) {
          const target = twin(input);
          if (!target) continue;
          const type = (input.type || '').toLowerCase();
          if (type === 'checkbox' || type === 'radio') {
            if (input.checked) target.setAttribute('checked', ''); else target.removeAttribute('checked');
          } else if (type !== 'file' && type !== 'password') {
            target.setAttribute('value', input.value);
          }
        }
        for (const area of live.filter(element => element.tagName === 'TEXTAREA')) {
          const target = twin(area);
          if (target) target.textContent = area.value;
        }
        for (const option of live.filter(element => element.tagName === 'OPTION')) {
          const target = twin(option);
          if (!target) continue;
          if (option.selected) target.setAttribute('selected', ''); else target.removeAttribute('selected');
        }
        for (const [element, values] of frozenValues) {
          const target = twin(element);
          if (!target) continue;
          for (const [property, value] of values) target.style.setProperty(property, value, 'important');
        }
        for (const canvas of live.filter(element => element.tagName === 'CANVAS')) {
          const target = twin(canvas);
          if (!target) continue;
          try {
            const image = document.createElement('img');
            image.src = canvas.toDataURL('image/png');
            for (const name of ['id', 'class', 'style', 'width', 'height']) {
              const value = target.getAttribute(name);
              if (value !== null) image.setAttribute(name, value);
            }
            const box = canvas.getBoundingClientRect();
            if (box.width > 0 && !canvas.style.width) image.style.width = box.width + 'px';
            if (box.height > 0 && !canvas.style.height) image.style.height = box.height + 'px';
            target.replaceWith(image);
          } catch (_) {
            // A canvas with drawings from another origin cannot be read; it stays as it is.
          }
        }
        const still = document.createElement('style');
        still.textContent = '*, *::before, *::after { animation: none !important; transition: none !important; }';
        (copy.querySelector('head') || copy).appendChild(still);

        let doctype = '';
        if (document.doctype) doctype = new XMLSerializer().serializeToString(document.doctype) + '\n';
        const closedDetails = live.filter(element => element.tagName === 'DETAILS' && !element.open).length;
        return JSON.stringify({ html: doctype + copy.outerHTML, closedDetails });
        """#

    /// A preparation script that opens every `<details>` of the copy being laid out, never the live page. A group of
    /// exclusive details (`name`) would close the others as each one opens, so the group is undone first.
    public static let openDetailsJavaScript = #"""
        for (const details of Array.from(document.querySelectorAll('details'))) {
          details.removeAttribute('name');
          details.open = true;
        }
        """#
}
