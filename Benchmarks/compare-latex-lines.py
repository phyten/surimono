#!/usr/bin/env python3
"""Compare TeX line ends by semantic context, using the plan and the physically printed rows.

Usage: python3 Benchmarks/compare-latex-lines.py DUMP OLD_PDFS REFERENCE_PDFS [--after-pdfs DIR] [--reader DIR] [--json RESULT] [--tsv TABLE]
With --after-pdfs, WordGapPt is the median ordinary gap on non-final lines, PeriodGapPt
measures gaps after sentence punctuation, and AllWordGapPt includes final lines.
Percent changes use the two exported PDFs. A missing measurement is not a zero-width gap.
Requires Poppler's pdftotext. All three inputs are read-only.
"""

import argparse
import csv
import io
import json
import re
from statistics import median
import subprocess
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path

from latex_line_sources import ParagraphSources


def normalized(text):
    # PDF word boundaries need not match the DOM's. Keep letters, digits, case and punctuation.
    text = unicodedata.normalize("NFKC", text)
    return "".join(text.split()).replace("\u00ad", "").translate(str.maketrans("\u2010\u2011", "--"))


@dataclass(frozen=True)
class Line:
    number: int
    page: int
    left: float
    right: float
    top: float
    text: str
    words: tuple


@dataclass(frozen=True)
class Word:
    page: int
    left: float
    right: float
    top: float
    height: float
    text: str


def column_lines(words, page_widths, start):
    # Some PDF producers paint both columns' review numbers in the outer margin and the
    # left column itself. Recognise a vertical sequence by shape, alignment and numbering.
    labels = defaultdict(list)
    for w in words:
        if re.fullmatch(r"\d{3}", w.text):
            labels[w.page, round(w.right), round(w.height, 1)].append(w)
    furniture = set()
    for group in labels.values():
        run = []
        for w in sorted(group, key=lambda v: v.top):
            if run and (int(w.text) != int(run[-1].text) + 1 or w.top <= run[-1].top):
                if len(run) >= 6:
                    furniture.update(run)
                run = []
            run.append(w)
        if len(run) >= 6:
            furniture.update(run)

    pages = defaultdict(list)
    for w in words:
        if w not in furniture:
            pages[w.page].append(w)
    columns = []
    whole_pages = []
    cuts = {}
    for page, page_words in pages.items():
        mid = page_widths[page] / 2
        # Asymmetric margins move the gutter away from the paper's exact midpoint. Within a
        # narrow central band choose the closest cut which crosses the fewest word boxes.
        cut = min(range(round(mid) - 12, round(mid) + 13),
                  key=lambda x: (sum(w.left < x < w.right for w in page_words), abs(x - mid)))
        cuts[page] = cut
        # Collect glyph runs at the same vertical centre. Never take one half of a continuous
        # full-width line: a row crossing the centre must have a visible inter-column gutter.
        rows = []
        for w in sorted(page_words, key=lambda v: v.top + v.height / 2):
            center = w.top + w.height / 2
            if not rows or center - rows[-1][0] > 0.39 * max(w.height, rows[-1][1][0].height):
                rows.append((center, []))
            rows[-1][1].append(w)
        lanes = [[], []]
        full = []
        for _, row in rows:
            row.sort(key=lambda w: w.left)
            full.append(Line(start, page, row[0].left, row[-1].right, min(w.top for w in row),
                             normalized("".join(w.text for w in row)), tuple(row)))
            start += 1
            left = [w for w in row if (w.left + w.right) / 2 < cut]
            right = [w for w in row if (w.left + w.right) / 2 >= cut]
            crosses = any(w.left < cut < w.right for w in row)
            narrow = left and right and right[0].left - left[-1].right < 0.75 * row[0].height
            for lane, segment in zip(lanes, (left, right)):
                if not segment:
                    continue
                # The placeholder prevents joining text on opposite sides of an ineligible row.
                value = "" if crosses or narrow else normalized("".join(w.text for w in segment))
                lane.append(Line(start, page, segment[0].left, segment[-1].right, min(w.top for w in segment), value, tuple(segment)))
                start += 1
        columns.extend(lanes)
        whole_pages.extend(full)
    return columns, cuts, whole_pages


class PrintedParagraphs:
    def __init__(self, pdf):
        # TSV preserves Poppler's flow/line membership without an XHTML metadata preamble.
        data = subprocess.run(["pdftotext", "-enc", "UTF-8", "-tsv", str(pdf), "-"],
                              check=True, capture_output=True, timeout=60)
        self.lines = []
        page_widths = {}
        row = None
        words = []
        word_boxes = []

        def finish():
            if row and words:
                left = float(row["left"])
                self.lines.append(Line(len(self.lines), int(row["page_num"]), left, left + float(row["width"]),
                                       float(row["top"]), normalized("".join(w.text for w in words)), tuple(words)))

        for record in csv.DictReader(io.StringIO(data.stdout.decode()), delimiter="\t", quoting=csv.QUOTE_NONE):
            level = record["level"]
            if level == "1":
                page_widths[int(record["page_num"])] = float(record["width"])
            if level == "4":
                finish()
                row, words = record, []
            if level == "5":
                left = float(record["left"])
                word_boxes.append(Word(int(record["page_num"]), left, left + float(record["width"]),
                                       float(record["top"]), float(record["height"]), record["text"]))
                words.append(word_boxes[-1])
        finish()
        self.lines = [line for line in self.lines if line.text]
        # Reading order is Poppler's by default. On two-column pages it can interleave the other
        # column or margin line numbers. Test a second order for each half, omitting crossing lines.
        # A match must still consume every source character, from the first to the last PDF line.
        self.by_number = {line.number: line for line in self.lines}
        self.page_widths = page_widths
        self.orders = [self.lines]
        for side in ("left", "right"):
            lane = []
            for line in self.lines:
                middle = page_widths[line.page] / 2
                if (side == "left" and line.right <= middle) or (side == "right" and line.left >= middle):
                    lane.append(line)
            self.orders.append(sorted(lane, key=lambda line: (line.page, line.top, line.left)))

        self.columns, self.cuts, self.full_rows = column_lines(word_boxes, page_widths, max(self.by_number, default=-1) + 1)
        self.by_number.update((line.number, line) for line in self.full_rows)
        self.by_number.update((line.number, line) for column in self.columns for line in column)

    def follows(self, earlier, later):
        a, b = self.by_number[earlier], self.by_number[later]
        if a.page != b.page:
            return a.page < b.page
        middle = self.cuts.get(a.page, self.page_widths[a.page] / 2)
        if a.right <= middle <= b.left:
            return True
        if b.right <= middle <= a.left:
            return False
        return a.top < b.top

    def match(self, source, category="body", physical=False):
        target = normalized(source)
        if not target:
            return None, "empty text"
        matches = {}
        # Prefer the original PDF text flow. Geometric reconstruction is a fallback for merges.
        orders_to_try = ([self.full_rows], self.columns) if physical else (self.orders, self.columns, [self.full_rows])
        for orders in orders_to_try:
            self.match_orders(orders, target, matches, category)
            if matches:
                break
        if not matches:
            self.match_across_columns(target, matches, category)
        if len(matches) != 1:
            return None, "ambiguous" if matches else "text or line boundaries differ"
        return next(iter(matches.items())), None

    @staticmethod
    def next_offset(target, offset, line, category):
        value = line.text
        if offset == 0 and not target.startswith(value.rstrip("-")):
            # A hanging label can be in the same Poppler line or in its own text object.
            # Only the first physical line of these contexts may omit such a prefix.
            pattern = {"list": r"^(?:[•◦▪‣–−\x88]|\(?[a-zA-Z0-9]+[.)])",
                       "bibliography": r"^\[[^]]{1,20}\]", "footnote": r"^(?:\d{1,3}|[*∗†‡§¶‖]+)"}.get(category)
            if pattern:
                value = re.sub(pattern, "", value, count=1)
        # Prefer the literal hyphen; only a physical line ending may add a discretionary.
        if (not target.startswith(value, offset) and value.endswith("-")
                and len(value) > 1 and offset + len(value) - 1 < len(target)):
            value = value[:-1]
        return offset + len(value) if value and target.startswith(value, offset) else None

    def match_orders(self, orders, target, matches, category):
        for order in orders:
            for start, line in enumerate(order):
                if not line.text or (line.text[0] != target[0] and category not in {"list", "bibliography", "footnote"}):
                    continue
                offsets = []
                end = 0
                for index in range(start, len(order)):
                    end = self.next_offset(target, end, order[index], category)
                    if end is None:
                        break
                    offsets.append(end)
                    if end == len(target):
                        ids = tuple(item.number for item in order[start:index + 1])
                        matches[ids] = offsets
                        break

    def match_across_columns(self, target, matches, category):
        # A float, a footnote or a running head can intervene when a paragraph changes
        # column or page. Match *complete consecutive lines* in each adjacent column.
        # Only the physical column boundary may be crossed; all characters and the
        # full sequence of participating lines must still have exactly one match.
        for current, following in zip(self.columns, self.columns[1:]):
            for start in range(len(current)):
                offset = 0
                prefix = []
                for line in current[start:]:
                    offset = self.next_offset(target, offset, line, category)
                    if offset is None:
                        break
                    prefix.append((line.number, offset))
                if not prefix or prefix[-1][1] == len(target):
                    continue
                for start2 in range(len(following)):
                    end = prefix[-1][1]
                    suffix = []
                    for line in following[start2:]:
                        end = self.next_offset(target, end, line, category)
                        if end is None:
                            break
                        suffix.append((line.number, end))
                        if end == len(target):
                            ids, offsets = zip(*(prefix + suffix))
                            matches[ids] = list(offsets)
                            break



def inventory(result, reader):
    diagnostics = result["paragraphs"]
    if len(diagnostics) != result["qualifying"]:
        raise ValueError("Expected one diagnostic per qualifying paragraph")
    rows = list(diagnostics)
    if reader:
        remaining = Counter((p.get("category", "body"), normalized(p["text"])) for p in diagnostics)
        for source in ParagraphSources().read(reader.read_text()):
            key = source["category"], normalized(source["text"])
            if remaining[key]:
                remaining[key] -= 1
            else:
                rows.append({**source, "readerOnly": True})
    return rows


def plan_ends(paragraph, source):
    lines = paragraph.get("lines") or []
    if not lines or not all(isinstance(line.get("text"), str) for line in lines):
        return None
    text = normalized(paragraph.get("runInHeading", ""))
    offsets = []
    for line in lines:
        text += normalized(line["text"])
        offsets.append(len(text))
    return offsets[:-1] if text == normalized(source) else None


def compare_offsets(row, ends, counts):
    before, after, reference = (ends[key] for key in ("before", "after", "reference"))
    for key, value in ends.items():
        if value is not None:
            row[key + "Breaks"] = value
            row[key] = len(value) + 1
    counts["matched"] += 1
    for name in ("before", "after"):
        counts[name + "EqualLines"] += row[name] == row["reference"]
    if after is None:
        return
    counts["matchedWithBreaks"] += 1
    counts["referenceEnds"] += len(reference)
    for name, current in (("before", before), ("after", after)):
        counts[name + "EqualBreaks"] += current == reference
        hits = len(set(current).intersection(reference))
        counts[name + "MatchingEnds"] += hits
        row[name + "MatchingEnds"] = hits
    row["worse"] = len(after) > len(before) or row["afterMatchingEnds"] < row["beforeMatchingEnds"]


def printed_gaps(pdf, match, source):
    """Measure adjacent word rectangles at source whitespace on the same printed baseline."""
    target = normalized(source)
    boundaries = {}
    end = 0
    tokens = source.split()
    for left, right in zip(tokens, tokens[1:]):
        end += len(normalized(left))
        if right.strip(".,;:)") == "mm" or left in ("=", "+", "−", "×", "·") or right in ("=", "+", "−", "×", "·"):
            continue
        # Sentence/block skips are a separate population, particularly after BibTeX newblock.
        boundaries[end] = "period" if re.search(r"""[.!?:]["'’”)\]]*$""", left) else "word"

    ids, offsets = match
    rows = []
    for index, (number, end) in enumerate(zip(ids, offsets)):
        line = pdf.by_number[number]
        start = offsets[index - 1] if index else 0
        content = target[start:end]
        # Exclude a hanging mark at the start and the discretionary at the end.
        printed = line.text if line.text.endswith(content) else line.text.removesuffix("-")
        offset = start - (len(printed) - len(content))
        gaps = {"word": [], "period": []}
        for left, right in zip(line.words, line.words[1:]):
            offset += len(normalized(left.text))
            kind = boundaries.get(offset)
            gap = right.left - left.right
            if kind and gap > 0.3 and abs((left.top + left.height) - (right.top + right.height)) <= 2.5:
                gaps[kind].append(gap)
        rows.append(gaps)
    return rows


def gap_columns(row, samples):
    medians = defaultdict(dict)
    for name, lines in samples.items():
        for kind, label, selected in (("word", "Word", lines[:-1]), ("period", "Period", lines[:-1]),
                                      ("word", "AllWord", lines)):
            values = [v for line in selected for v in line[kind]]
            if values:
                medians[label][name] = median(values)
                row[name + label + "GapPt"] = round(medians[label][name], 3)
        row[name + "LineWordGapsPt"] = [round(median(line["word"]), 3) if line["word"] else None for line in lines]
    for label, versions in medians.items():
        if "before" in versions and "after" in versions:
            ratio = versions["after"] / versions["before"]
            prefix = label[0].lower() + label[1:]
            row[prefix + "GapChangePercent"] = round(100 * (ratio - 1), 2)
            row[prefix + "GapsWider20"] = ratio > 1.2

    # A loose line can disappear in the paragraph median. Compare corresponding
    # line numbers only when both versions occupy the same number of rows.
    old, new = samples.get("before"), samples.get("after")
    if old and new and len(old) == len(new):
        row["widerWordGapLines"] = [i + 1 for i, (a, b) in enumerate(zip(old, new))
                                    if a["word"] and b["word"] and median(b["word"]) > 1.2 * median(a["word"])]


def compare_document(records, pdfs, physical):
    rows = []
    counts = defaultdict(Counter)
    exclusions = Counter()
    sources = [p.get("runInHeading", "") + p["text"] for p in records]
    repeats = Counter(map(normalized, sources))
    last_body = {}
    alignments = []
    for i, (p, source) in enumerate(zip(records, sources)):
        category = p.get("category", "body")
        row = {"paragraph": i, "anchor": p["text"][:100], "category": category,
               "fallback": p.get("fallback"), "readerOnly": bool(p.get("readerOnly"))}
        samples = {}
        ends, reasons = {}, {}
        if repeats[normalized(source)] > 1:
            reasons["source"] = "repeated paragraph"
        for name, pdf in pdfs.items():
            if isinstance(pdf, str):
                reasons[name] = pdf
                continue
            if not physical and name == "after":
                plan = plan_ends(p, source)
                if plan is not None:
                    ends[name] = plan
                    continue
                if p.get("lines"):
                    reasons[name] = "plan text differs from source"
                    continue
            match, why = pdf.match(source, category, physical)
            if physical and "source" not in reasons:
                # A geometric row can merge with its neighbour. Poppler's own
                # line membership is an independent way to locate the same words.
                gap_match = match or pdf.match(source, category)[0]
                if gap_match:
                    samples[name] = printed_gaps(pdf, gap_match, source)
            if match is None:
                reasons[name] = why
            else:
                ids, offsets = match
                if category == "body":
                    previous = last_body.get(name)
                    if previous and not pdf.follows(previous[0], ids[0]):
                        reasons[name] = "PDF paragraphs out of source order"
                        previous[1][name] = reasons[name]
                    last_body[name] = (ids[-1], reasons)
                ends[name] = offsets[:-1]
                row[name + "Location"] = [pdf.by_number[ids[0]].page, round(pdf.by_number[ids[0]].top, 1)]
        if "after" not in pdfs:
            after = plan_ends(p, source)
            native_count = p.get("renderedLineCount")
            if after is None and not (p.get("fallback") and isinstance(native_count, int) and native_count > 0):
                reasons["after"] = "no complete plan and no after PDF"
            row["after"] = native_count
            ends["after"] = after
        if samples:
            gap_columns(row, samples)
            for prefix, count in (("word", "matchedWordGaps"), ("allWord", "matchedAllWordGaps")):
                flag = prefix + "GapsWider20"
                if flag in row:
                    counts[category][count] += 1
                    counts[category][flag] += int(row[flag])
        alignments.append((row, ends, reasons))
    for row, ends, reasons in alignments:
        category = row["category"]
        if reasons:
            # Missing reference text still allows a regression in the two exports to be reported.
            for name, offsets in ends.items():
                if name not in reasons and offsets is not None:
                    row[name + "Breaks"] = offsets
                    row[name] = len(offsets) + 1
            if not ({"before", "after", "source"} & reasons.keys()) and row.get("before") and row.get("after"):
                row["worse"] = row["after"] > row["before"]
            row["excluded"] = reasons
            exclusions.update(f"{key}: {why}" for key, why in reasons.items())
        else:
            compare_offsets(row, ends, counts[category])
        counts[category]["sources"] += 1
        rows.append(row)
    return rows, counts, exclusions


def run(dump, old_dir, ref_dir, after_dir=None, reader_dir=None):
    documents = sorted(dump.glob("[0-9][0-9][0-9]*.json"))
    if not documents:
        raise ValueError(f"No NNN-name.json line dumps in {dump}")
    summary = Counter()
    methods = {"plan": defaultdict(Counter)}
    if after_dir:
        methods["physical"] = defaultdict(Counter)
    excluded = defaultdict(Counter)
    fallbacks = defaultdict(Counter)
    paragraphs = defaultdict(list)
    seen = set()
    for file in documents:
        ident = file.name[:3]
        if ident in seen:
            raise ValueError(f"Multiple dumps for {ident}")
        seen.add(ident)
        result = json.loads(file.read_text())
        records = inventory(result, reader_dir / (file.stem + ".html") if reader_dir else None)
        summary.update(documents=1, qualifying=result["qualifying"], fallbacks=result["fallbacks"])
        for p in result["paragraphs"]:
            if p.get("fallback"):
                fallbacks[p.get("category", "body")][p["fallback"]] += 1
        if not records:
            continue
        pdfs = {}
        for name, folder in (("before", old_dir), ("reference", ref_dir), ("after", after_dir)):
            if folder:
                pdf = folder / (ident + ".pdf")
                try:
                    pdfs[name] = PrintedParagraphs(pdf)
                except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
                    pdfs[name] = f"PDF unavailable ({pdf.name}: {error})"
        for method, categories in methods.items():
            rows, counts, errors = compare_document(records, pdfs, method == "physical")
            for category, values in counts.items():
                categories[category].update(values)
            excluded[method].update(errors)
            paragraphs[method].extend(dict(row, document=ident) for row in rows)
    totals = {name: sum(categories.values(), Counter()) for name, categories in methods.items()}
    return {"counts": {**summary, **totals["plan"]},
            "methods": methods, "totals": totals, "fallbackReasons": fallbacks,
            "exclusions": excluded if after_dir else excluded["plan"],
            "paragraphs": paragraphs["plan"], "physicalParagraphs": paragraphs["physical"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dump", type=Path)
    parser.add_argument("old_pdfs", type=Path)
    parser.add_argument("reference_pdfs", type=Path)
    parser.add_argument("--after-pdfs", type=Path, help="also compare the physical printed rows of both exports")
    parser.add_argument("--reader", type=Path, help="include native and skipped contexts from make latex-dump")
    parser.add_argument("--json", type=Path, help="write per-paragraph counts, break positions, physical word gaps in points, and exclusions")
    parser.add_argument("--tsv", type=Path, help="write a paragraph table with line ends and word-gap changes in percent")
    args = parser.parse_args()
    if args.tsv and not args.after_pdfs:
        parser.error("--tsv requires --after-pdfs for physical word gaps")
    try:
        result = run(args.dump, args.old_pdfs, args.reference_pdfs, args.after_pdfs, args.reader)
    except (OSError, ValueError) as error:
        parser.exit(2, f"{error}\n")
    if args.tsv:
        fields = ["document", "paragraph", "category", "anchor", "before", "after", "reference", "beforeMatchingEnds",
                  "afterMatchingEnds", "referenceWordGapPt", "beforeWordGapPt", "afterWordGapPt", "wordGapChangePercent",
                  "wordGapsWider20", "widerWordGapLines", "allWordGapChangePercent", "allWordGapsWider20",
                  "beforePeriodGapPt", "afterPeriodGapPt", "periodGapChangePercent", "excluded"]
        with args.tsv.open("w", encoding="utf-8", newline="") as output:
            writer = csv.DictWriter(output, fields, delimiter="\t", extrasaction="ignore")
            writer.writeheader()
            writer.writerows(result["physicalParagraphs"])
    if args.json:
        args.json.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key not in ("paragraphs", "physicalParagraphs")},
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
