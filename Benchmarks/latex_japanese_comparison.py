"""Compare physical Japanese body lines by source character offset rather than space-delimited words."""

import json
import re

from latex_line_sources import Element, ParagraphSources

JAPANESE = re.compile(r"[ぁ-ヺ一-鿿]")
NON_BODY = {"head", "nav", "header", "figure", "table", "aside", "li", "dd", "script", "style", "template"}
NON_BODY_CLASSES = {"abstract", "footnotes", "latex-front-abstract", "latex-bibliography", "latex-title-block"}


def body_paragraphs(node, category="body"):
    if node.tag in NON_BODY or NON_BODY_CLASSES.intersection(node.classes):
        return
    if node.tag == "blockquote":
        category = "quote"
    if node.tag == "p":
        yield category, node
        return
    for child in node.children:
        if isinstance(child, Element):
            yield from body_paragraphs(child, category)


def measured_lines(plan, normalize):
    """The dump stores the gap before each token. A break discards that gap and any final space."""
    if not plan:
        return {}
    rows = {}
    start = offset = 0
    for end in plan["ends"]:
        tokens = plan["tokens"][start:end]
        previous_offset = offset
        offset += sum(len(normalize(t[0])) for t in tokens)
        natural = sum(t[2] for t in tokens) + sum(t[3] for t in tokens[1:])
        if tokens[-1][1] == "space":
            natural -= tokens[-1][2]
        unit = plan["cssPerTeXPoint"]
        rows[previous_offset, offset] = {
            "naturalPt": natural / unit, "measurePt": (plan["width"] - (0 if start else plan["indent"])) / unit,
        }
        start = end
    return rows


def boxes(folder, stem, normalize):
    path = folder / (stem + ".json")
    plans = json.loads(path.read_text()).get("japanese", []) if path.is_file() else []
    return {normalize(p["text"]): measured_lines(p, normalize) for p in plans}


def line_material(text, following, tagged):
    marks = "、。，．「」『』（）【】ーっゃゅょ"
    labels = []
    if re.search(r"[a-zA-Z]", text):
        labels.append("Latin")
    if re.search(r"\d", text):
        labels.append("digits")
    if any(c in text for c in "、。，．・：；「」『』（）【】"):
        labels.append("punctuation")
    if any(c in marks for c in text[:1] + text[-1:] + following[:1]):
        labels.append("kinsoku-edge")
    if any(c in text for c in "  "):
        labels.append("thin-space")
    if re.search(r"[ぁ-ヺ一-鿿][a-zA-Z0-9]|[a-zA-Z0-9][ぁ-ヺ一-鿿]", text):
        labels.append("Western-boundary")
    return sorted(set(labels) | tagged) or ["Japanese"]


def source_characters(node, normalize, tags=frozenset()):
    # Keep the original punctuation and thin spaces alongside offsets in Poppler's normalized text.
    tags = set(tags)
    if node.tag in {"ruby", "sup"}:
        tags.add("ruby" if node.tag == "ruby" else "mark")
    if node.tag in {"script", "style", "template"}:
        return
    if node.tag == "svg" or "math-inline" in node.classes:
        tags.add("math")
    for child in node.children:
        if isinstance(child, Element):
            if "qed" not in child.classes:
                yield from source_characters(child, normalize, tags)
        else:
            for char in child:
                yield char, len(normalize(char)), tags


def match_lines(printed, text, decorated):
    match, issue = printed.match(text, physical=True)
    if not match:
        match, issue = printed.match(text)
    if match:
        # Poppler can split one printed line into multiple flows at a font change.
        ids, ends = match
        breaks = []
        previous = None
        for number, end in zip(ids, ends):
            line = printed.by_number[number]
            if previous and previous.page == line.page and previous.right <= line.left + 1:
                # Japanese and Latin faces on one baseline can have different top bearings.
                height = min(max(w.height for w in r.words) for r in (previous, line))
                same_row = abs(previous.top - line.top) <= 0.35 * height
                cut = printed.cuts.get(line.page)
                if same_row and not (cut and previous.right <= cut <= line.left):
                    breaks.pop()
            breaks.append(end)
            previous = line
        return breaks, None
    if decorated:
        # A run-in heading or a drawn QED may share its row. Accept only a unique complete body substring.
        hits = [line for line in printed.full_rows if text in line.text]
        if len(hits) == 1:
            return [len(text)], None
    return None, issue


def compare_japanese(reader, references, before, after, pdf_reader, normalize, dump, before_dump):
    result = []
    for html in sorted(reader.glob("*.html")):
        markup = html.read_text()
        source = ParagraphSources()
        source.read(markup)
        japanese_language = re.search(r'<html[^>]+lang="ja(?:-[^"]*)?"', markup)
        candidates = [(category, node) for category, node in body_paragraphs(source.node) if JAPANESE.search(node.prose())]
        if not japanese_language and not any(re.search(r"[ぁ-ヺ]", node.prose()) for _, node in candidates):
            continue
        number = html.name[:3]
        entry = {"document": number, "paragraphs": []}
        result.append(entry)
        if not (references / (number + ".pdf")).is_file():
            entry["error"] = "no reference PDF"
            continue
        versions = {name: pdf_reader(folder / (number + ".pdf")) for name, folder in
                    [("reference", references), ("before", before), ("after", after)]}
        widths = {name: boxes(folder, html.stem, normalize) for name, folder in [("before", before_dump), ("after", dump)]}
        for category, node in candidates:
            chars = list(source_characters(node, normalize))
            text = "".join(c for c, _, _ in chars)
            target = normalize(text)
            record = {"text": text, "category": category, "lines": {}}
            entry["paragraphs"].append(record)
            decorated = "latex-runin" in node.parent.classes or any(isinstance(c, Element) and "qed" in c.classes for c in node.children)
            for name, printed in versions.items():
                ends, issue = match_lines(printed, target, decorated)
                if ends is None:
                    record.setdefault("excluded", {})[name] = issue
                    continue
                record["lines"][name] = ends
            if "excluded" in record:
                continue
            offsets = [0]
            for _, length, _ in chars:
                offsets.append(offsets[-1] + length)
            details = {}
            for name, ends in record["lines"].items():
                start = 0
                for i, end in enumerate(ends):
                    others = [v for k, v in record["lines"].items() if k != name]
                    if any(i >= len(v) or v[i] != end for v in others):
                        first, last = offsets.index(start), offsets.index(end)
                        fragment = text[first:last]
                        row = {"line": i + 1, "break": fragment[-6:] + "|" + text[last:last+6],
                               "material": line_material(fragment, text[last:], {tag for _, _, tags in chars[first:last] for tag in tags})}
                        row.update(widths.get(name, {}).get(target, {}).get((start, end), {}))
                        details.setdefault(name, []).append(row)
                    start = end
            if details:
                record["differences"] = details
        paired = [p["lines"] for p in entry["paragraphs"] if "excluded" not in p]
        for name in ("before", "after"):
            entry[name] = {"matched": len(paired), "lines": sum(len(p[name]) for p in paired),
                           "differentEnds": sum(len(set(p["reference"][:-1]) - set(p[name][:-1])) for p in paired),
                           "extraEnds": sum(len(set(p[name][:-1]) - set(p["reference"][:-1])) for p in paired)}
    return result
