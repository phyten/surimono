// A text leaf is shaped in runs, but Japanese characters remain separate break
// candidates. Keep combining marks and variation selectors on their base glyph.
const graphemes = new Intl.Segmenter('ja', { granularity: 'grapheme' });
const japaneseGlyph = /[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\u3000-\u303f\u30a0-\u30ff\uff01-\uff60]/u;
const japaneseLetter = /[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}ー]/u;
const startsWestern = /^(?:\p{sc=Latin}|\p{Nd})/u;
const endsWestern = /(?:\p{sc=Latin}|\p{Nd})\p{M}*$/u;
const noLineStart = new Set(Array.from('、。，．・：；？！ー々ゝゞヽヾぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿｰｧｨｩｪｫｯｬｭｮ)]}）］｝〕〉》」』】〙〗〟’”,.!?:;%％'));
const noLineEnd = new Set(Array.from('([{（［｛〔〈《「『【〘〖〝‘“'));

function labelParts(value) {
  const parts = [];
  let word = '';
  for (const { segment } of graphemes.segment(value)) {
    if (segment === ' ' || segment === '-' || japaneseGlyph.test(segment) || noLineStart.has(segment) || noLineEnd.has(segment)) {
      if (word) parts.push(word);
      word = '';
      parts.push(segment);
    } else word += segment;
  }
  if (word) parts.push(word);
  return parts;
}

function labelGlue(left, right) {
  if (!left || left.noAutospace || right.noAutospace) return 0;
  if (left.ja && japaneseLetter.test(left.text) && startsWestern.test(right.text) && !right.ja)
    return left.zw / 4;
  if (right.ja && japaneseLetter.test(right.text) && endsWestern.test(left.text) && !left.ja)
    return right.zw / 4;
  return 0;
}

function canWrap(left, right, space) {
  if (!right) return true;
  if (left.keep && left.keep === right.keep) return false;
  if (noLineEnd.has(left.text) || noLineStart.has(right.text)
      || /[\u00a0\u2060]$/u.test(left.text) || /^[\u00a0\u2060]/u.test(right.text)) return false;
  return space || left.text === '-' || left.ja || right.ja || left.math || right.math;
}

// All widths, skips and baselines use the same units. Scanning the next line
// again is bounded: only the final unbreakable group can pass the last break.
function layoutLabel(atoms, width, leading, align) {
  const lines = [];
  function paragraph(items) {
    let start = 0;
    if (!items.length) lines.push({ runs: [], width: 0 });
    while (start < items.length) {
      let best = null, natural = 0, shrink = 0, previous;
      for (let i = start; i < items.length; ++i) {
        const a = items[i];
        natural += labelGlue(previous, a) + a.advance;
        if (previous?.ja && a.ja) shrink += Math.min(previous.shrink, a.shrink);
        previous = a;
        if (width !== null && natural - shrink > width + 1e-7) break;
        if (a.text === ' ') continue;
        const spaced = items[i + 1]?.text === ' ';
        const next = i + (spaced ? 2 : 1);
        if (canWrap(a, items[next], spaced)) best = { end: i + 1, next, natural, shrink };
      }
      if (!best) throw new Error('text width');
      const compression = width === null ? 0 : Math.max(0, best.natural - width);
      let x = 0;
      const runs = [];
      previous = null;
      for (let i = start; i < best.end; ++i) {
        const a = items[i];
        x += labelGlue(previous, a);
        if (compression && best.shrink > 0 && previous?.ja && a.ja)
          x -= compression * Math.min(previous.shrink, a.shrink) / best.shrink;
        runs.push({ atom: a, x });
        x += a.advance;
        previous = a;
      }
      lines.push({ runs, width: x });
      start = best.next;
    }
  }
  let items = [];
  for (const a of atoms) {
    if (a.text === '\n') {
      if (items.at(-1)?.text === ' ') items.pop();
      paragraph(items);
      items = [];
    } else if (a.text !== ' ' || (items.length && items.at(-1).text !== ' ')) items.push(a);
  }
  if (items.at(-1)?.text === ' ') items.pop();
  paragraph(items);

  let w = width ?? 0, top = 0, bottom = 0;
  if (width === null) for (const line of lines) w = Math.max(w, line.width);
  for (const [i, line] of lines.entries()) {
    line.y = i * leading;
    line.x = align === 'right' ? w - line.width : align === 'center' ? (w - line.width) / 2 : 0;
    bottom = Math.max(bottom, line.y);
    for (const { atom } of line.runs) {
      top = Math.min(top, line.y + atom.shift - atom.ascent);
      bottom = Math.max(bottom, line.y + atom.shift + atom.depth);
    }
  }
  return { lines, w, h: bottom - top, baseY: -top, lastBaseY: lines.at(-1).y - top };
}
