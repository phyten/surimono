// Work on the private print DOM after its fonts, images and diagrams have settled.
await document.fonts.ready;
const frames = Array.from(document.querySelectorAll('section.beamer-frame'));
const continued = new Set();
const pages = [];
// TeX stacks the block body's box below the ink depth of the title's last line.
// CSS line boxes reserve descent even when the last line contains no descenders.
const metrics = document.createElement('canvas').getContext('2d');
function blockTitleDepth(title) {
    const lines = document.createRange();
    lines.selectNodeContents(title);
    const last = Array.from(lines.getClientRects()).filter(rect => rect.height).at(-1);
    if (!metrics || !last) return 0;
    const walker = document.createTreeWalker(title, NodeFilter.SHOW_TEXT);
    let depth = 0;
    for (let text; (text = walker.nextNode());) {
        if (!text.length || text.parentElement.closest('svg')) continue;
        lines.selectNodeContents(text);
        const fragments = lines.getClientRects();
        if (!fragments.length || fragments[fragments.length-1].bottom < last.top) continue;
        // The first character on the final line may be inside a single wrapped text node.
        let lo = 0, hi = text.length;
        while (lo < hi) {
            const mid = Math.floor((lo + hi) / 2);
            lines.setStart(text, mid); lines.setEnd(text, mid+1);
            if (lines.getBoundingClientRect().bottom <= last.top) lo = mid+1;
            else hi = mid;
        }
        const style = getComputedStyle(text.parentElement);
        // Canvas rounds ink bounds to device pixels. Measure at a large size to keep
        // the slight overshoot of round letters distinct from a lowercase descender.
        const size = parseFloat(style.fontSize);
        metrics.font = style.fontStyle + ' ' + style.fontWeight + ' ' + (size * 32) + 'px ' + style.fontFamily;
        depth = Math.max(depth, metrics.measureText(text.data.slice(lo)).actualBoundingBoxDescent / 32);
    }
    return depth;
}
for (const title of document.querySelectorAll('.beamer-block-title'))
    title.parentElement.style.setProperty('--beamer-title-depth', blockTitleDepth(title) + 'px');
// TeX sets the distance between two ordinary lines from the receiving paragraph's
// pitch (at its closing size) and the vertical skips between their baselines.
function alignListBaselines(content) {
    const nested = 'li > :is(ul,ol)';
    const ordinary = 'ul:not([class],[style]),ol.latex-enumerate:not([style])';
    const measured = [];
    function marker() {
        const span = document.createElement('span');
        span.style.cssText = 'display:inline-block;position:relative;width:0;height:0;line-height:0;vertical-align:baseline';
        return span;
    }
    // Tall boxes and local font-size changes can trigger TeX's minimum lineskip.
    // Only ordinary paragraph text and its inline emphasis use this baseline distance.
    function plain(el) {
        if (!el.textContent.trim() || el.hasAttribute('style') || el.querySelector(':not(span,a,em,strong,i,b),[style]')) return false;
        // A theme can change an inline font through a class without an inline style.
        const size = getComputedStyle(el).fontSize;
        return size === getComputedStyle(el.parentElement).fontSize &&
            [...el.querySelectorAll('*')].every(run => getComputedStyle(run).fontSize === size);
    }
    function firstLine(item) {
        return item?.firstElementChild?.matches('p') ? item.firstElementChild : item;
    }
    function measure(previous, first, block, skip, closing = []) {
        if (!first || !previous || !plain(previous) || !plain(first) || block.hasAttribute('style')) return;
        const item = first.closest('li'), parent = item?.parentElement.closest('li');
        const level = parent ? (parent.parentElement.closest('li') ? 2 : 1) : 0;
        const closesAt = level + (first.matches('p') && first.nextElementSibling?.hasAttribute('data-beamer-closes-paragraph') ? 1 : 0);
        const pitch = ['var(--beamer-pitch, calc(13.6 * var(--tex-pt)))',
            'var(--beamer-small-pitch, calc(12 * var(--tex-pt)))',
            'var(--beamer-note-pitch, calc(11 * var(--tex-pt)))'][Math.min(closesAt, 2)];
        const from = marker(), to = marker(), ruler = document.createElement('span');
        ruler.style.cssText = 'position:absolute;display:block;height:0;width:calc('
            + pitch + ' + ' + skip + ' * var(--tex-pt))';
        from.append(ruler);
        measured.push({block, previous, first, from, to, ruler, closing});
    }
    for (const list of content.querySelectorAll(ordinary)) {
        const parent = list.parentElement, inside = parent.matches('li');
        if (parent.closest('li') && (!inside || !parent.parentElement.matches(ordinary))) continue;
        const nestedList = inside || list.querySelector(nested) !== null;
        const topsep = inside ? 2 : 3;
        if (nestedList && list.previousElementSibling?.matches('p')) {
            measure(list.previousElementSibling, firstLine(list.firstElementChild), list, topsep);
        }

        const next = list.nextElementSibling || (inside && parent.nextElementSibling);
        if (!next) continue;
        let first, skip;
        if (next.matches(ordinary) || (!inside && next.matches('dl.latex-description:not(.latex-nextline,[style])'))) {
            if (next.matches('dl')) {
                first = next.querySelector(':scope > div:first-child > dt');
                const definition = first?.nextElementSibling;
                if (!definition?.matches('dd') || !plain(firstLine(definition))) continue;
            } else {
                first = firstLine(next.firstElementChild);
            }
            // Consecutive lists each contribute their own topsep, once on exit and once on entry.
            skip = 2 * topsep;
        } else if (nestedList && next.matches('p')) {
            first = next;
            skip = topsep;
        } else if (inside && next.matches('li')) {
            first = firstLine(next);
            // The enclosing item's itemsep coalesces with the child's closing topsep.
            skip = Math.max(topsep, parent.parentElement.closest('li') ? 0 : 3);
        } else {
            continue;
        }
        // Consecutive list endings coalesce to the outer closing skip. Follow the
        // last item to its actual last line, even when multiple lists end there.
        const closing = [list];
        let last = list.lastElementChild;
        while (last?.lastElementChild?.matches(ordinary)) {
            const child = last.lastElementChild;
            closing.push(child);
            last = child.lastElementChild;
        }
        if (last?.lastElementChild?.matches('p')) last = last.lastElementChild;
        measure(last, first, next, skip, closing);
    }
    for (const {previous, first, from, to, closing} of measured) {
        // Put the entire measured skip on the receiving block. A collapsed trailing
        // margin on any list ending here would otherwise mask a smaller correction.
        for (const list of closing) list.style.marginBlockEnd = '0px';
        previous.append(from);
        first.prepend(to);
    }
    // Read every distance before writing margins: moving an outer list carries both
    // ends of an inner measurement together. The ruler shares the print view's zoom.
    for (const entry of measured) {
        const {block, from, to, ruler} = entry;
        const span = ruler.getBoundingClientRect().width;
        const pitch = parseFloat(getComputedStyle(ruler).width);
        if (span > 0 && pitch > 0) {
            const gap = to.getBoundingClientRect().bottom - from.getBoundingClientRect().bottom;
            entry.margin = parseFloat(getComputedStyle(block).marginTop) + pitch * (1 - gap / span);
        }
    }
    for (const {block, from, to, margin, closing} of measured) {
        from.remove(); to.remove();
        if (Number.isFinite(margin)) block.style.marginBlockStart = margin + 'px';
        else for (const list of closing) list.style.removeProperty('margin-block-end');
    }
}
function roman(value) {
    let result = '';
    for (const [n, letters] of [[1000,'M'],[900,'CM'],[500,'D'],[400,'CD'],[100,'C'],[90,'XC'],[50,'L'],
                                [40,'XL'],[10,'X'],[9,'IX'],[5,'V'],[4,'IV'],[1,'I']]) {
        while (value >= n) { result += letters; value -= n; }
    }
    return result;
}
function continuation(frame, count) {
    const title = frame.querySelector('.beamer-frame-title');
    if (title) title.append(' ' + roman(count));
}
function scaled(body, factor) {
    // Zoom changes both the paint and the flex item's intrinsic height. Preserve the line measure.
    const width = body.getBoundingClientRect().width;
    const shell = document.createElement('div');
    shell.style.cssText = 'display:flow-root;margin:0;zoom:' + factor + ';width:' + width + 'px';
    shell.append(...Array.from(body.childNodes));
    body.append(shell);
}
function newPage(previous, heading) {
    const copy = previous.cloneNode(false);
    copy.removeAttribute('id');
    if (heading) {
        const title = heading.cloneNode(true);
        title.removeAttribute('id');
        title.querySelectorAll('[id]').forEach(el => el.removeAttribute('id'));
        copy.append(title);
    }
    const body = document.createElement('div');
    body.className = 'beamer-frame-body';
    copy.append(body);
    previous.after(copy);
    return [copy, body];
}
function splitInside(block, bottom) {
    // A paragraph, list, or subdivisible block that is taller than a slide can break on a
    // real line boundary. Cloning the Range ancestry keeps emphasis, list nesting and links.
    const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
    let last = null;
    for (let text; (text = walker.nextNode());) {
        if (!text.length || text.parentElement.closest('svg,math,ruby')) continue;
        const range = document.createRange();
        range.selectNodeContents(text);
        if (range.getBoundingClientRect().bottom <= bottom) {
            last = [text, text.length];
            continue;
        }
        let lo = 0, hi = text.length;
        while (lo < hi) {
            const middle = Math.ceil((lo + hi) / 2);
            range.setEnd(text, middle);
            if (range.getBoundingClientRect().bottom <= bottom) lo = middle;
            else hi = middle - 1;
        }
        if (lo) last = [text,lo];
        break;
    }
    if (!last) return null;
    const rest = document.createRange();
    rest.selectNodeContents(block);
    rest.setStart(...last);
    if (!rest.toString().trim() && !rest.cloneContents().querySelector('img,svg,canvas,table')) return null;
    const tail = block.cloneNode(false);
    tail.removeAttribute('id');
    tail.append(rest.extractContents());
    // A Range crossing an anchor clones its ancestors; only the first piece is a destination.
    const retained = new Set(Array.from(block.querySelectorAll('[id]'), el => el.id));
    tail.querySelectorAll('[id]').forEach(el => { if (retained.has(el.id)) el.removeAttribute('id'); });
    return tail;
}
for (const frame of frames) {
    const ordinal = Number(frame.dataset.frame);
    const content = frame.querySelector(':scope > .beamer-frame-body');
    if (!content) continue;
    alignListBaselines(content);
    let heading = frame.querySelector(':scope > .beamer-frame-heading');
    let notes = frame.querySelector(':scope > .beamer-footnotes');
    const frameHeight = frame.getBoundingClientRect().height;
    const pitch = parseFloat(getComputedStyle(content).lineHeight) || parseFloat(getComputedStyle(content).fontSize);
    const bottomInset = parseFloat(getComputedStyle(frame).paddingBottom);
    const topInset = frame.dataset.align === 't' ? parseFloat(getComputedStyle(frame,'::before').height) : 0;
    // A title or note which is itself taller than the paper must enter the same breakable flow.
    if (heading && heading.offsetHeight + bottomInset + topInset + pitch > frameHeight) {
        content.prepend(heading); heading = null;
    }
    const titleHeight = heading?.getBoundingClientRect().height || 0;
    if (notes && titleHeight + notes.offsetHeight + bottomInset + topInset + pitch > frameHeight) {
        content.append(notes); notes = null;
    }
    const originalHeading = heading?.cloneNode(true);
    const noteHeight = notes?.getBoundingClientRect().height || 0;
    const room = frameHeight - titleHeight - noteHeight - topInset - bottomInset;
    const explicit = frame.hasAttribute('data-allowframebreaks');
    let height = content.getBoundingClientRect().height;
    const shrink = frame.hasAttribute('data-shrink');
    if (shrink && Number(frame.dataset.shrink) > 0) {
        const factor = Math.max(.01, 1 - Math.min(99, Number(frame.dataset.shrink)) / 100);
        content.style.width = content.getBoundingClientRect().width / factor + 'px';
        height = content.getBoundingClientRect().height;
        scaled(content, Math.min(factor, room / Math.max(1,height)));
        content.style.width = '';
        pages.push(ordinal);
        continue;
    }
    if (!explicit && (shrink || height <= room * 1.08)) {
        if (height > room) scaled(content, room / height);
        pages.push(ordinal);
        continue;
    }
    // TeX's default split fraction is .95 for allowframebreaks. Automatically continued
    // frames use the whole available body, so an ordinary slide never breaks prematurely.
    const portion = Number(frame.dataset.allowframebreaks);
    const fraction = explicit && height > room ? (portion > 0 && portion <= 1 ? portion : .95) : 1;
    if (notes) notes.remove();
    const breaks = Array.from(content.querySelectorAll('.beamer-break'));
    for (const marker of breaks) {
        // Lift a break inside a paragraph without flattening the surrounding inline elements.
        if (marker.parentNode === content) continue;
        const tail = document.createRange();
        tail.selectNodeContents(content);
        tail.setStartAfter(marker);
        const remainder = tail.extractContents();
        content.append(marker, remainder);
    }
    const pending = Array.from(content.childNodes).reverse();
    content.replaceChildren();
    let page = frame, body = content, count = 1;
    const discardable = '.latex-vspace:not([data-latex-keep-space])';
    // A page break consumes ordinary vertical glue. Wait for the following box before
    // deciding whether the glue fits with it; a starred skip is itself a box at the break.
    let glue = [];
    let capacity;
    function measurePage() {
        const title = page.querySelector(':scope > .beamer-frame-heading');
        // The Roman numeral can wrap an otherwise single-line title. Reserve its actual height.
        const base = frameHeight - topInset - Math.max(bottomInset,parseFloat(getComputedStyle(page).paddingBottom)) - noteHeight;
        capacity = (base - (title?.getBoundingClientRect().height || 0)) * fraction;
        if (capacity < pitch && title) {
            // Preserve the full title and leave one body line when the numeral creates an extra row.
            title.style.zoom = Math.min(1, Math.max(1, base - pitch) / title.getBoundingClientRect().height);
            capacity = (base - title.getBoundingClientRect().height) * fraction;
        }
        capacity = Math.max(1, capacity);
    }
    function next() {
        // Reject pathological dimensions before allocating thousands of clipped DOM subtrees.
        if (pages.length >= 10000) throw new RangeError('Slide page limit');
        pages.push(ordinal);
        [page, body] = newPage(page, originalHeading);
        continuation(page, ++count);
        measurePage();
    }
    if (explicit || height > room) continuation(frame, count);
    measurePage();
    while (pending.length) {
        const node = pending.pop();
        if (node.nodeType === Node.TEXT_NODE && !node.textContent.trim()) { body.append(node); continue; }
        if (node.nodeType === Node.ELEMENT_NODE && node.matches('.beamer-break')) {
            glue = [];
            if (body.children.length || body.textContent.trim()) next();
            continue;
        }
        if (node.nodeType === Node.ELEMENT_NODE && node.matches(discardable)) {
            glue.push(node);
            continue;
        }
        const occupied = body.getBoundingClientRect().height > 0;
        const preceding = occupied || count === 1 ? glue : [];
        glue = [];
        body.append(...preceding);
        body.append(node);
        if (body.getBoundingClientRect().height <= capacity + .1) continue;
        if (occupied) {
            node.remove();
            preceding.forEach(skip => skip.remove());
            pending.push(node); next(); continue;
        }
        if (node.nodeType !== Node.ELEMENT_NODE) continue;
        const tail = splitInside(node, body.getBoundingClientRect().top + capacity - 1);
        if (tail) { pending.push(tail); next(); continue; }
        // An indivisible graphic taller than the page is tiled at its native scale.
        const height = body.getBoundingClientRect().height;
        if (!Number.isFinite(height) || Math.ceil(height / capacity) + pages.length > 10000)
            throw new RangeError('Slide page limit');
        const tile = node.cloneNode(true);
        for (let offset = 0; offset < height;) {
            if (offset) next();
            const window = document.createElement('div');
            window.style.cssText = 'display:flow-root;overflow:hidden;height:' + Math.min(capacity,height-offset) + 'px';
            const piece = offset ? tile.cloneNode(true) : node;
            if (offset) {
                piece.removeAttribute('id');
                piece.querySelectorAll('[id]').forEach(el => el.removeAttribute('id'));
            }
            if (offset) piece.style.transform = 'translateY(-' + offset + 'px)';
            window.append(piece); body.append(window);
            offset += capacity;
        }
    }
    if (notes) page.append(notes);
    if (!explicit && count > 1) continued.add(ordinal);
    pages.push(ordinal);
}
return JSON.stringify({frames:pages, continued:continued.size});
