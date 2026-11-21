#!/usr/bin/env python3
"""Compare the same uniquely matched paragraphs in a line dump and two sets of PDFs.

Usage: python3 Benchmarks/compare-latex-lines.py DUMP OLD_PDFS REFERENCE_PDFS [--json RESULT]
Requires Poppler's pdftotext. All three inputs are read-only.
"""

import argparse
import csv
import io
import json
import re
import subprocess
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path


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
        for _, row in rows:
            row.sort(key=lambda w: w.left)
            left = [w for w in row if (w.left + w.right) / 2 < cut]
            right = [w for w in row if (w.left + w.right) / 2 >= cut]
            crosses = any(w.left < cut < w.right for w in row)
            narrow = left and right and right[0].left - left[-1].right < 0.75 * row[0].height
            for lane, segment in zip(lanes, (left, right)):
                if not segment:
                    continue
                # The placeholder prevents joining text on opposite sides of an ineligible row.
                value = "" if crosses or narrow else normalized("".join(w.text for w in segment))
                lane.append(Line(start, page, segment[0].left, segment[-1].right, min(w.top for w in segment), value))
                start += 1
        columns.extend(lanes)
    return columns, cuts


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
                                       float(row["top"]), normalized("".join(words))))

        for record in csv.DictReader(io.StringIO(data.stdout.decode()), delimiter="\t", quoting=csv.QUOTE_NONE):
            level = record["level"]
            if level == "1":
                page_widths[int(record["page_num"])] = float(record["width"])
            if level == "4":
                finish()
                row, words = record, []
            if level == "5":
                words.append(record["text"])
                left = float(record["left"])
                word_boxes.append(Word(int(record["page_num"]), left, left + float(record["width"]),
                                       float(record["top"]), float(record["height"]), record["text"]))
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

        self.columns, self.cuts = column_lines(word_boxes, page_widths, max(self.by_number, default=-1) + 1)
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

    def match(self, source):
        target = normalized(source)
        if not target:
            return None, "empty text"
        matches = {}
        # Prefer the original PDF text flow. Geometric reconstruction is a fallback for merges.
        for orders in (self.orders, self.columns):
            self.match_orders(orders, target, matches)
            if matches:
                break
        if not matches:
            self.match_across_columns(target, matches)
        if len(matches) != 1:
            return None, "ambiguous" if matches else "text or line boundaries differ"
        return next(iter(matches.items())), None

    @staticmethod
    def next_offset(target, offset, line):
        value = line.text
        # Prefer the literal hyphen; only a physical line ending may add a discretionary.
        if (not target.startswith(value, offset) and value.endswith("-")
                and len(value) > 1 and offset + len(value) - 1 < len(target)):
            value = value[:-1]
        return offset + len(value) if value and target.startswith(value, offset) else None

    def match_orders(self, orders, target, matches):
        for order in orders:
            for start, line in enumerate(order):
                if not line.text or line.text[0] != target[0]:
                    continue
                offsets = []
                end = 0
                for index in range(start, len(order)):
                    end = self.next_offset(target, end, order[index])
                    if end is None:
                        break
                    offsets.append(end)
                    if end == len(target):
                        ids = tuple(item.number for item in order[start:index + 1])
                        matches[ids] = offsets
                        break

    def match_across_columns(self, target, matches):
        # A float, a footnote or a running head can intervene when a paragraph changes
        # column or page. Match *complete consecutive lines* in each adjacent column.
        # Only the physical column boundary may be crossed; all characters and the
        # full sequence of participating lines must still have exactly one match.
        for current, following in zip(self.columns, self.columns[1:]):
            for start in range(len(current)):
                offset = 0
                prefix = []
                for line in current[start:]:
                    offset = self.next_offset(target, offset, line)
                    if offset is None:
                        break
                    prefix.append((line.number, offset))
                if not prefix or prefix[-1][1] == len(target):
                    continue
                for start2 in range(len(following)):
                    end = prefix[-1][1]
                    suffix = []
                    for line in following[start2:]:
                        end = self.next_offset(target, end, line)
                        if end is None:
                            break
                        suffix.append((line.number, end))
                        if end == len(target):
                            ids, offsets = zip(*(prefix + suffix))
                            matches[ids] = list(offsets)
                            break



def run(dump, old_dir, ref_dir):
    documents = sorted(dump.glob("[0-9][0-9][0-9]*.json"))
    if not documents:
        raise ValueError(f"No NNN-name.json line dumps in {dump}")
    counts = Counter()
    exclusions = Counter()
    rows = []
    seen = set()
    for file in documents:
        ident = file.name[:3]
        if ident in seen:
            raise ValueError(f"Multiple dumps for {ident}")
        seen.add(ident)
        result = json.loads(file.read_text())
        paragraphs = result["paragraphs"]
        if len(paragraphs) != result["qualifying"]:
            raise ValueError(f"{file.name}: expected one diagnostic per qualifying paragraph")
        counts["documents"] += 1
        counts["qualifying"] += len(paragraphs)
        counts["fallbacks"] += result["fallbacks"]
        if not paragraphs:
            continue
        pdfs = {}
        errors = {}
        for name, folder in (("before", old_dir), ("reference", ref_dir)):
            pdf = folder / (ident + ".pdf")
            try:
                pdfs[name] = PrintedParagraphs(pdf)
            except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
                errors[name] = f"PDF unavailable ({pdf.name}: {error})"
        # A run-in heading shares the first printed line with the measured body.
        # Include it on both sides so that matching still consumes complete PDF lines.
        sources = [p.get("runInHeading", "") + p["text"] for p in paragraphs]
        source_counts = Counter(map(normalized, sources))
        first_record = len(rows)
        last_matches = {}
        for i, (p, source) in enumerate(zip(paragraphs, sources)):
            record = {"document": ident, "paragraph": i, "anchor": p["text"][:100], "fallback": p.get("fallback")}
            reasons = errors.copy()
            if source_counts[normalized(source)] > 1:
                reasons["source"] = "repeated paragraph"
            for name, pdf in pdfs.items():
                match, why = pdf.match(source)
                if why:
                    reasons[name] = why
                else:
                    line_ids, offsets = match
                    previous = last_matches.get(name)
                    if previous and not pdf.follows(previous[0], line_ids[0]):
                        reasons[name] = "PDF paragraphs out of source order"
                        previous[1]["excluded"][name] = reasons[name]
                    last_matches[name] = (line_ids[-1], record)
                    record[name] = len(line_ids)
                    record[name + "Breaks"] = offsets[:-1]
            lines = p.get("lines") or []
            after = p.get("renderedLineCount") if p.get("fallback") else len(lines)
            if not isinstance(after, int) or after < 1:
                reasons["after"] = "no rendered line count"
            else:
                record["after"] = after
            if lines and all(isinstance(line.get("text"), str) for line in lines):
                text, offsets = normalized(p.get("runInHeading", "")), []
                for line in lines:
                    text += normalized(line["text"])
                    offsets.append(len(text))
                if text == normalized(source):
                    record["afterBreaks"] = offsets[:-1]
            record["excluded"] = reasons
            rows.append(record)
        for record in rows[first_record:]:
            reasons = record.pop("excluded")
            if reasons:
                record["excluded"] = reasons
                for label, why in reasons.items():
                    exclusions[f"{label}: {why}"] += 1
                continue
            counts["matched"] += 1
            counts["beforeEqualLines"] += record["before"] == record["reference"]
            counts["afterEqualLines"] += record["after"] == record["reference"]
            if "afterBreaks" in record:
                counts["matchedWithBreaks"] += 1
                counts["beforeEqualBreaks"] += record["beforeBreaks"] == record["referenceBreaks"]
                counts["afterEqualBreaks"] += record["afterBreaks"] == record["referenceBreaks"]
    keys = ("documents", "qualifying", "fallbacks", "matched", "beforeEqualLines", "afterEqualLines",
            "matchedWithBreaks", "beforeEqualBreaks", "afterEqualBreaks")
    return {"counts": {key: counts[key] for key in keys}, "exclusions": dict(exclusions), "paragraphs": rows}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dump", type=Path)
    parser.add_argument("old_pdfs", type=Path)
    parser.add_argument("reference_pdfs", type=Path)
    parser.add_argument("--json", type=Path, help="write per-paragraph counts, break positions, and exclusions")
    args = parser.parse_args()
    try:
        result = run(args.dump, args.old_pdfs, args.reference_pdfs)
    except (OSError, ValueError) as error:
        parser.exit(2, f"{error}\n")
    if args.json:
        args.json.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({key: result[key] for key in ("counts", "exclusions")}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
