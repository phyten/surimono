// Keep the parser's default paragraph breaks, including single newlines.
function surimonoConvert(source) {
    const mark = definitionMark(source);
    const gathered = gatherDefinitionLists(source, mark);
    const html = module.exports(gathered.text);
    return {html: gathered.wrapped ? unwrapDefinitionLists(html, mark) : html};
}

// textile-js 2.1.1 ends a definition list after a single newline. The blank line that follows stays
// in the input, so the next block starts with a newline and prints as text without its paragraph:
// every second item of a list written with blank lines between items, and the paragraph after any list.
// The library stays unmodified. Each run of one-line items at a block boundary goes into a marked div,
// with the blank lines between items removed, and the div is taken off again after conversion. The
// library parses a div's content as blocks only when it contains a blank line, which the comment provides.
//
// Everything here reads a line once, front to back. The document is untrusted and a regular expression
// that can backtrack over a few dozen characters would run on after the converter's time limit.
const definitionItem = /^- .*?:=[ \t]*\S/;
const blankLine = /^[ \t]*\r?$/;
const blockNames = ["notextile", "pre", "div", "bc", "bq", "###"];
const literalBlocks = new Set(["notextile", "pre", "bc", "###"]);
const rawOpening = /<!--|<(pre|notextile|code|script|style)\b/gi;

// A marker the document does not contain, so the unwrapping can only remove what this conversion added: the base
// name followed by one more "x" than any occurrence of it in the document. Found in one pass. (A hyphen would end
// the marker comment early.)
function definitionMark(source) {
    const base = "surimono-textile-dl";
    let longest = -1;
    for (let index = source.indexOf(base); index >= 0; index = source.indexOf(base, index + base.length)) {
        let end = index + base.length;
        while (source[end] === "x") end++;
        longest = Math.max(longest, end - index - base.length);
    }
    return base + "x".repeat(longest + 1);
}

function gatherDefinitionLists(source, mark) {
    const lines = source.split("\n");
    const output = [];
    let wrapped = false;
    let boundary = true;
    // Inside an extended block (`bc..`), until the next block signature.
    let extended = false;
    // Inside a block whose text the library keeps as written: no raw HTML opens there.
    let literal = false;
    // The open raw HTML element or comment, read across lines.
    let raw = null;
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (raw) {
            output.push(line);
            raw = afterRawHTML(line, raw);
            boundary = blankLine.test(line);
            continue;
        }
        if (extended) {
            const signature = blockSignature(line);
            if (!signature) {
                output.push(line);
                continue;
            }
            // The signature that closes an extended block opens the next one.
            extended = signature.extended;
            literal = literalBlocks.has(signature.name);
            output.push(line);
            if (!literal) raw = afterRawHTML(line, null);
            boundary = false;
            continue;
        }
        if (blankLine.test(line)) {
            output.push(line);
            boundary = true;
            literal = false;
            continue;
        }
        if (boundary) {
            const signature = blockSignature(line);
            if (signature) {
                extended = signature.extended;
                literal = literalBlocks.has(signature.name);
            } else if (startsItem(lines, i)) {
                const run = definitionRun(lines, i);
                if (run.accepted) {
                    output.push('<div class="' + mark + '">', "<!--" + mark + "-->", "");
                    for (const item of run.items) output.push(item);
                    output.push("</div>");
                    wrapped = true;
                } else {
                    // Left to the library as written, once. The next search starts after the whole run.
                    for (let line = i; line < run.end; line++) output.push(lines[line]);
                }
                i = run.end - 1;
                boundary = run.end > 0 && blankLine.test(lines[run.end - 1]);
                continue;
            }
        }
        output.push(line);
        if (!literal) raw = afterRawHTML(line, null);
        boundary = false;
    }
    return {text: output.join("\n"), wrapped};
}

// The library's block signature: a name, attributes, then `.` or `..` before a space, a colon or the end.
// Attributes are `(class)`, `{style}`, `[lang]`, alignment and any run of parentheses as padding. An attribute
// list can be read in more than one way, so this keeps the set of positions it can reach, in one pass.
function blockSignature(line) {
    let start = -1;
    let name = null;
    for (const block of blockNames) {
        if (line.startsWith(block)) {
            start = block.length;
            name = block;
            break;
        }
    }
    if (name === null) {
        const heading = /^h[1-6]/.exec(line) || /^fn\d+/.exec(line) || /^p/.exec(line);
        if (!heading) return null;
        start = heading[0].length;
        name = heading[0][0] === "f" ? "fn" : heading[0];
    }
    // The first closing character at or after each position, found from the end of the line once.
    const next = {")": [], "}": [], "]": [], "[": []};
    for (const key in next) {
        let found = -1;
        next[key] = new Array(line.length + 1);
        for (let index = line.length; index >= 0; index--) {
            if (line[index] === key) found = index;
            next[key][index] = found;
        }
    }
    const reached = new Uint8Array(line.length + 1);
    reached[start] = 1;
    let extended = null;
    for (let index = start; index <= line.length; index++) {
        if (!reached[index]) continue;
        const char = line[index];
        if (char === ".") {
            const after = line[index + 1];
            const ends = c => c === undefined || c === ":" || /\s/.test(c);
            if (after === "." && ends(line[index + 2])) extended = true;
            else if (ends(after) && extended === null) extended = false;
        }
        if (index === line.length) break;
        if (char === "(" || char === ")") reached[index + 1] = 1;
        if (char === "<" && line[index + 1] === ">") reached[index + 2] = 1;
        if (char === "<" || char === ">" || char === "=") reached[index + 1] = 1;
        if (char === "(") {
            const close = next[")"][index + 1];
            if (close > index + 1) reached[close + 1] = 1;
        }
        if (char === "{") {
            const close = next["}"][index + 1];
            if (close > index + 1) reached[close + 1] = 1;
        }
        if (char === "[") {
            const close = next["]"][index + 1];
            const open = next["["][index + 1];
            if (close > index + 1 && (open < 0 || open > close)) reached[close + 1] = 1;
        }
    }
    return extended === null ? null : {name, extended};
}

// The raw HTML state after a line: null, or the element or comment still open at its end.
function afterRawHTML(line, open) {
    let index = 0;
    while (index <= line.length) {
        if (open) {
            const closing = open === "!--" ? /-->/gi : new RegExp("</" + open + "\\s*>", "gi");
            closing.lastIndex = index;
            const found = closing.exec(line);
            if (!found) return open;
            index = found.index + found[0].length;
            open = null;
        }
        rawOpening.lastIndex = index;
        const found = rawOpening.exec(line);
        if (!found) return null;
        open = found[1] ? found[1].toLowerCase() : "!--";
        index = found.index + found[0].length;
    }
    return open;
}

// Terms written on their own lines belong to the next item, as in the library.
function startsItem(lines, line) {
    while (line < lines.length && lines[line].startsWith("- ") && !definitionItem.test(lines[line])) line++;
    return line < lines.length && definitionItem.test(lines[line]);
}

// Items with their terms and continuation lines, from `start` to `end`, the line after the run (a blank line or
// the end). A run the library reads differently is not accepted: a definition written as a block, or raw HTML
// that could close the marked div or stay open after it.
function definitionRun(lines, start) {
    const items = [];
    let accepted = true;
    let raw = null;
    let line = start;
    while (true) {
        if (!definitionItem.test(lines[line])) {
            if (/:=[ \t]*\r?$/.test(lines[line])) {
                // A block definition runs to its `=:`; the library reads it from here. Move past at least one line.
                return {accepted: false, end: Math.max(line, start + 1)};
            }
            items.push(lines[line]);
            line++;
            continue;
        }
        let end = line + 1;
        while (end < lines.length && !blankLine.test(lines[end]) && !lines[end].startsWith("- ")) end++;
        for (let index = line; index < end; index++) {
            const item = lines[index];
            items.push(item);
            if (/<\/?div\b/i.test(item)) accepted = false;
            raw = afterRawHTML(item, raw);
        }
        if (end < lines.length && lines[end].startsWith("- ")) {
            if (!startsItem(lines, end)) return {accepted: false, end};
            line = end;
            continue;
        }
        let next = end;
        while (next < lines.length && blankLine.test(lines[next])) next++;
        if (next < lines.length && startsItem(lines, next)) {
            line = next;
            continue;
        }
        return {accepted: accepted && raw === null, items, end};
    }
}

function unwrapDefinitionLists(html, mark) {
    const pattern = new RegExp(
        '<div class="' + mark + '">\\n?<!--' + mark + "-->\\n?(<dl>[\\s\\S]*?</dl>)\\n?</div>", "g");
    return html.replace(pattern, "$1");
}
