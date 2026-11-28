// Keep the parser's default paragraph breaks, including single newlines.
function surimonoConvert(source) {
    return {html: unwrapDefinitionLists(module.exports(gatherDefinitionLists(source)))};
}

// textile-js 2.1.1 ends a definition list after a single newline. The blank line that follows stays
// in the input, so the next block starts with a newline and prints as text without its paragraph:
// every second item of a list written with blank lines between items, and the paragraph after any list.
// The library stays unmodified. Each run of one-line items at a block boundary goes into a marked div,
// with the blank lines between items removed, and the div is taken off again after conversion. The
// library parses a div's content as blocks only when it contains a blank line, which the comment provides.
const definitionMark = "surimono-textile-dl";
const definitionItem = /^- .*?:=[ \t]*\S/;
const blankLine = /^[ \t]*\r?$/;
const blockSignature =
    /^(?:bc|pre|notextile|bq|p|div|h[1-6]|fn\d+|###)(?:\([^)]+\)|\{[^}]+\}|\[[^[\]]+\]|<>|<|>|=|[()]+)*\.(\.?)(?:\s|:|$)/;
const rawOpening = /^\s*<(pre|notextile|code|script|style)\b/i;

function gatherDefinitionLists(source) {
    const lines = source.split("\n");
    const output = [];
    let boundary = true;
    let extended = false;
    let rawClosing = null;
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (rawClosing) {
            output.push(line);
            if (rawClosing.test(line)) rawClosing = null;
            continue;
        }
        if (extended) {
            const signature = blockSignature.exec(line);
            if (!signature) {
                output.push(line);
                continue;
            }
            extended = false;
        }
        if (blankLine.test(line)) {
            output.push(line);
            boundary = true;
            continue;
        }
        if (boundary) {
            const signature = blockSignature.exec(line);
            const raw = rawOpening.exec(line);
            if (signature) {
                extended = signature[1] === ".";
            } else if (raw) {
                const closing = new RegExp("</" + raw[1] + "\\s*>", "i");
                if (!closing.test(line)) rawClosing = closing;
            } else if (/^\s*<!--/.test(line) && !/-->/.test(line)) {
                rawClosing = /-->/;
            } else if (startsItem(lines, i)) {
                const run = definitionRun(lines, i);
                if (run) {
                    output.push('<div class="' + definitionMark + '">', "<!--" + definitionMark + "-->", "");
                    output.push(...run.items, "</div>");
                    i = run.end - 1;
                    boundary = false;
                    continue;
                }
            }
        }
        output.push(line);
        boundary = false;
    }
    return output.join("\n");
}

// Terms written on their own lines belong to the next item, as in the library.
function startsItem(lines, line) {
    while (line < lines.length && lines[line].startsWith("- ") && !definitionItem.test(lines[line])) line++;
    return line < lines.length && definitionItem.test(lines[line]);
}

// Items with their terms and continuation lines, from `start` to the line after the last item (a blank line or
// the end). Returns null for a run the library reads differently: a definition written as a block, or raw HTML
// that could close the marked div.
function definitionRun(lines, start) {
    const items = [];
    let line = start;
    while (true) {
        if (!definitionItem.test(lines[line])) {
            if (/:=[ \t]*\r?$/.test(lines[line])) return null;
            items.push(lines[line]);
            line++;
            continue;
        }
        let end = line + 1;
        while (end < lines.length && !blankLine.test(lines[end]) && !lines[end].startsWith("- ")) end++;
        items.push(...lines.slice(line, end));
        if (end < lines.length && lines[end].startsWith("- ")) {
            if (!startsItem(lines, end)) return null;
            line = end;
            continue;
        }
        let next = end;
        while (next < lines.length && blankLine.test(lines[next])) next++;
        if (next < lines.length && startsItem(lines, next)) {
            line = next;
            continue;
        }
        if (items.some(item => /<\/?div\b/i.test(item))) return null;
        return {items, end};
    }
}

function unwrapDefinitionLists(html) {
    const pattern = new RegExp(
        '<div class="' + definitionMark + '">\\n?<!--' + definitionMark + "-->\\n?(<dl>[\\s\\S]*?</dl>)\\n?</div>", "g");
    return html.replace(pattern, "$1");
}
