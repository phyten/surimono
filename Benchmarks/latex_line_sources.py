"""Locate LaTeX contexts in a pristine reader dump, including paragraphs left to WebKit."""

from html.parser import HTMLParser


class Element:
    def __init__(self, tag, attrs, parent=None):
        self.tag = tag
        self.attrs = dict(attrs)
        self.classes = self.attrs.get("class", "").split()
        self.parent = parent
        self.children = []

    def prose(self):
        if self.tag in {"ul", "ol", "dl", "style", "script", "template"}:
            return ""
        if {"item-label", "latex-item-mark", "bib-label", "latex-symbolic-note"} & set(self.classes):
            return ""
        return "".join(c if isinstance(c, str) else c.prose() for c in self.children)


class ParagraphSources(HTMLParser):
    def __init__(self):
        super().__init__()
        self.node = Element("document", [])
        self.sources = []

    def handle_starttag(self, tag, attrs):
        if tag in {"meta", "link", "br", "hr", "img", "input", "wbr", "col", "source", "area", "base", "embed", "param", "track"}:
            return
        child = Element(tag, attrs, self.node)
        self.node.children.append(child)
        self.node = child

    def handle_endtag(self, tag):
        node = self.node
        while node.parent and node.tag != tag:
            node = node.parent
        if node.parent:
            self.node = node.parent

    def handle_data(self, data):
        self.node.children.append(data)

    def read(self, html):
        self.feed(html)
        self.close()
        self.visit(self.node, None, False, "")
        return self.sources

    def visit(self, node, category, enabled, language):
        if node.tag in {"head", "nav", "table", "style", "svg", "script", "template", "header"}:
            return
        if "abstract-title" in node.classes:
            return
        language = node.attrs.get("lang", language)
        if node.tag == "body":
            enabled = node.attrs.get("data-latex-line-breaking") in {"cm", "times"}
        if node.tag == "blockquote":
            category = "quotation" if "latex-quotation" in node.classes else (None if node.classes else "quote")
        elif node.tag == "figcaption":
            category = "caption"
        elif node.tag == "dd":
            category = "description"
        elif "footnotes" in node.classes:
            category = "footnote"
        elif "latex-bibliography" in node.classes:
            category = "bibliography"
        elif set(node.classes) & {"abstract", "latex-front-abstract"}:
            category = "abstract"
        elif "latex-minipage" in node.classes:
            category = "minipage"
        elif node.tag in {"ol", "ul"} and category not in {"bibliography", "footnote"}:
            category = "list"
        if enabled and category and language.split("-")[0].lower() == "en":
            explicit = any(isinstance(c, Element) and c.tag == "p" for c in node.children)
            if node.tag == "p" or (node.tag in {"li", "dd", "figcaption"} and not explicit):
                text = node.prose().strip()
                if text:
                    item = {"text": text, "category": category}
                    if node.tag == "dd" and "latex-nextline" not in node.parent.parent.classes:
                        label = next((c for c in node.parent.children if isinstance(c, Element) and c.tag == "dt"), None)
                        if label:
                            item["runInHeading"] = label.prose()
                    self.sources.append(item)
        for child in node.children:
            if isinstance(child, Element):
                self.visit(child, category, enabled, language)
