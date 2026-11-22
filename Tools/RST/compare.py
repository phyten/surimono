#!/usr/bin/env python3
"""Compare the rendered structure of our own fixtures. Docutils is an optional development executable."""
import argparse
import difflib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "Packages/SurimonoKit/Tests/SurimonoFormatsTests/Fixtures/RST"
VOID = set("area base br col embed hr img input link meta param source track wbr".split())
BLOCK = set("main header footer section aside div nav h1 h2 h3 h4 h5 h6 p hr pre ul ol li dl dt dd "
            "table thead tbody tr td th caption blockquote figure figcaption address line-block line footnote citation admonition display-math".split())


class Node:
    def __init__(self, tag, attrs=()):
        self.tag, self.attrs, self.children = tag, dict(attrs), []

    @property
    def classes(self):
        return self.attrs.get("class", "").split()

    def texts(self):
        return "".join(c if isinstance(c, str) else c.texts() for c in self.children)

    def find(self, tag):
        if self.tag == tag:
            return self
        return next((found for c in self.children if isinstance(c, Node)
                     for found in [c.find(tag)] if found is not None), None)


class Parser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = Node("body")
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        node = Node(tag, attrs)
        self.stack[-1].children.append(node)
        if tag not in VOID:
            self.stack.append(node)

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                break

    def handle_data(self, data):
        self.stack[-1].children.append(data)


def tidy(children, trim=False):
    result = []
    for child in children:
        if isinstance(child, str):
            child = re.sub(r"[ \n\r\t\f]+", " ", child)
            if result and isinstance(result[-1], str):
                result[-1] = re.sub(" +", " ", result[-1] + child)
                continue
        result.append(child)
    # HTML indent between block elements contributes no printed word space.
    for i, child in enumerate(result):
        if not isinstance(child, str):
            continue
        if (trim and i == 0) or (i and isinstance(result[i-1], list) and result[i-1][0] in BLOCK):
            child = child.lstrip(" ")
        if (trim and i == len(result)-1) or (i+1 < len(result) and isinstance(result[i+1], list) and result[i+1][0] in BLOCK):
            child = child.rstrip(" ")
        result[i] = child
    return [x for x in result if x != ""]


def semantic(node):
    if isinstance(node, str):
        return [node]
    t, a, cs = node.tag, node.attrs, node.classes
    if t in ("style", "script", "colgroup", "col", "head") or (t == "svg" and a.get("aria-hidden") == "true"):
        return []
    # Store only the existence of an oracle diagnostic, never its generated prose, path or source dump.
    if "system-messages" in cs or "system-message" in cs:
        return [["diagnostic"]]
    at = {k: a[k] for k in ("id", "href", "src", "alt", "rowspan", "colspan", "start", "type")
          if k in a and a[k] is not None}
    if "math-block" in cs and node.find("svg"):
        return [["display-math", node.find("svg").attrs.get("aria-label", node.texts()).strip()]]
    if t == "svg" and "aria-label" in a:
        return [["math", a["aria-label"]]]
    if "math" in cs and t in ("pre", "tt", "span", "div") and not node.find("svg"):
        return [["display-math" if t == "pre" else "math", node.texts().strip()]]
    if t == "pre":
        # Highlight token spans and code wrappers are visual. Keep inline markup in parsed literals.
        if node.find("a") or node.find("em") or node.find("strong"):
            return [["pre-markup", *[v for c in node.children for v in semantic(c)]]]
        return [["pre", node.texts().strip("\n")]]
    if t == "img" and at.get("src", "").startswith("file:"):
        from urllib.parse import unquote, urlsplit
        at["src"] = unquote(urlsplit(at["src"]).path).split("/RST/")[-1].split("/", 1)[-1]
    if "docinfo" in cs:
        rows = []
        def fields(n):
            if n.tag in ("dt", "dd", "th", "td"):
                value = [v for c in n.children for v in semantic(c)]
                if len(value) == 1 and isinstance(value[0], list) and value[0][0] == "p":
                    value = value[0][1:]
                if value and n.tag in ("dt", "th") and isinstance(value[-1], str):
                    value[-1] = value[-1].removesuffix(":")
                rows.append(["label" if n.tag in ("dt", "th") else "value", *tidy(value, True)])
            else:
                for c in n.children:
                    if isinstance(c, Node):
                        fields(c)
        fields(node)
        return [["docinfo", *rows]]
    # Move section anchors to their heading, where the app exposes them to its outline.
    if t in ("main", "section") and "id" in at:
        heading = next((c for c in node.children if isinstance(c, Node) and re.fullmatch("h[1-6]", c.tag)), None)
        if heading:
            heading.attrs.setdefault("id", at.pop("id"))
    children = tidy([v for c in node.children for v in semantic(c)], t in BLOCK or t == "body")
    if t == "ol":
        for name, kind in (("upperroman","I"),("lowerroman","i"),("upperalpha","A"),("loweralpha","a")):
            if name in cs:
                at["type"] = kind
        if at.get("type") == "1":
            at.pop("type")
        if at.get("start") == "1":
            at.pop("start")
    if t in ("li", "td", "th", "dd") and len(children) == 1 and isinstance(children[0], list) and children[0][0] == "p":
        children = children[0][1:]
    if t == "tt" or (t == "span" and "literal" in cs):
        t = "code"
    if t == "span":
        if "classifier" in cs:
            t = "classifier"
        elif not at:
            return children
    if t == "div" and "line-block" in cs:
        t = "line-block"
    elif t == "div" and "line" in cs:
        t = "line"
    elif "doc-footnote" == a.get("role") or "footnote" in cs:
        t = "footnote"
    elif "doc-biblioentry" == a.get("role") or "citation" in cs:
        t = "citation"
    elif "admonition" in cs or "callout" in cs:
        t = "admonition"
    elif "footnote-list" in cs or "citation-list" in cs:
        return children
    elif t in ("main", "body") or (t == "div" and not at):
        return children
    if t == "code" and node.tag == "span" and "literal" in cs:
        children = [node.texts()]
    return [[t, *([at] if at else []), *children]]


def printed_navigation(node, parent=None):
    """Docutils provides return trips for a browser. Paper keeps the label and the forward link."""
    content = []
    for child in node.children:
        if isinstance(child, Node):
            if node.attrs.get("role") in ("doc-footnote", "doc-biblioentry") and child.tag == "span" and "backrefs" in child.classes:
                continue
            printed_navigation(child, node)
            contents_title = (parent is not None and parent.tag == "nav" and "contents" in parent.classes
                              and "topic-title" in node.classes)
            if child.tag == "a" and (child.attrs.get("role") == "doc-backlink" or
                                     (contents_title and child.attrs.get("href") == "#top" and "internal" in child.classes)):
                content.extend(child.children)
                continue
        content.append(child)
    node.children = content


def tree(html, docutils=False):
    parser = Parser()
    parser.feed(html)
    parser.close()
    root = parser.root.find("main") or parser.root
    if docutils:
        printed_navigation(root)
    return semantic(root)


def serialized(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def oracle(executable, path):
    # Use the fixture directory for includes and the source name for relative image paths.
    result = subprocess.run([executable, "--syntax-highlight=none", "--no-generator",
                             "--math-output=LaTeX", "--link-stylesheet", "--report=2", path.name],
                            cwd=path.parent, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    html = result.stdout.decode("utf-8")
    if result.returncode != 0 or "<main" not in html:
        raise RuntimeError(f"{path}: rst2html5 exited {result.returncode}: {result.stderr.decode()}")
    return tree(html, docutils=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fixtures", type=Path, default=FIXTURES)
    ap.add_argument("--html", type=Path)
    ap.add_argument("--live", action="store_true")
    ap.add_argument("--update-oracle", action="store_true")
    args = ap.parse_args()
    fixtures = args.fixtures
    snapshots = fixtures / "oracle.json"
    cases = sorted(fixtures.glob("*/*.rst"))
    names = [str(p.relative_to(fixtures)) for p in cases]
    expected = {} if args.update_oracle else json.loads(snapshots.read_text())
    if args.live or args.update_oracle:
        exe = os.environ.get("RST2HTML5") or shutil.which("rst2html5")
        if not exe:
            sys.exit("rst2html5 missing (set RST2HTML5 to its path)")
        with ThreadPoolExecutor(max_workers=4) as pool:
            facts = dict(zip(names, pool.map(lambda p: oracle(exe, p), cases)))
        if args.update_oracle:
            snapshots.write_text("{\n" + ",\n".join("  " + serialized(n) + ": " + serialized(facts[n]) for n in names) + "\n}\n")
            return 0
        for name in names:
            if facts[name] != expected.get(name):
                sys.exit(f"Docutils output changed for {name}; review before updating stored facts")
    if set(names) != set(expected) or len(names) < 120:
        sys.exit("Oracle fixture inventory mismatch or fewer than 120 inputs")
    if args.html is None:
        sys.exit("--html required to compare the Swift reader")
    differences = json.loads((fixtures / "differences.json").read_text())
    equal = 0
    failures = 0
    for name in names:
        actual = tree((args.html / Path(name).with_suffix(".html")).read_text())
        if actual == expected[name]:
            equal += 1
            if name in differences:
                failures += 1
                print(f"NOW EQUAL {name}: remove its exception")
            elif args.live:
                print("EQUAL", name)
            continue
        item = differences.get(name, {})
        digest = hashlib.sha256(serialized(actual).encode()).hexdigest()
        known = item.get("sha256") == digest and bool(item.get("reason"))
        failures += not known
        print(f"{'DIFFERENT' if known else 'UNEXPECTED'} {name}: {item.get('reason','')} [{digest}]")
        if args.live or not known:
            for line in difflib.unified_diff(
                json.dumps(expected[name], ensure_ascii=False, indent=1).splitlines(),
                json.dumps(actual, ensure_ascii=False, indent=1).splitlines(), "Docutils", "Swift", n=2, lineterm=""):
                print(line)
    print(f"RST cases={len(names)} equal={equal} different={len(names)-equal} unexpected={failures}")
    return int(bool(failures or differences.keys() - set(names)))


if __name__ == "__main__":
    sys.exit(main())
