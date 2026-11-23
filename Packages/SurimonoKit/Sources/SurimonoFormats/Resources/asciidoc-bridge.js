// The browser build has no filesystem bindings. Keep its parser and HTML backend,
// adding only the diagram block names and marking math before inline delimiters are lost.
LoggerManager.setLogger(NullLogger.create());
Extensions.register(function () {
    for (const language of ['mermaid', 'plantuml', 'graphviz', 'dot']) {
        this.block(language, function () {
            this.onContexts('listing', 'literal', 'open');
            this.contentModel('verbatim');
            this.process(async function (parent, reader, attributes) {
                return this.createBlock(parent, 'listing', await reader.readLines(), {
                    ...attributes, style: 'source', language
                });
            });
        });
    }
});

// Asciidoctor builds an array as large as a table's span, row span, repeat count or column count: one cell spanning
// 9,999,999 columns took over 3 GB. The numbers it parsed itself are capped, so cell text that only looks like a
// specifier, custom separators and every table format keep Asciidoctor's own reading. (Tests set
// `surimonoUncappedTables` to compare the capped reading with the bundled parser's.)
const maximumTableSpan = 1000;
const parseCellspec = Parser.parseCellspec;
Parser.parseCellspec = function (...args) {
    const result = parseCellspec.apply(this, args);
    if (globalThis.surimonoUncappedTables) return result;
    const spec = result[0];
    if (spec) {
        for (const key of ['colspan', 'rowspan', 'repeatcol']) {
            if (spec[key] > maximumTableSpan) spec[key] = maximumTableSpan;
        }
    }
    return result;
};
const parseColspecs = Parser.parseColspecs;
Parser.parseColspecs = function (records, ...rest) {
    if (typeof records !== 'string' || globalThis.surimonoUncappedTables) {
        return parseColspecs.call(this, records, ...rest);
    }
    // The parser's own first steps: spaces removed once, then a plain number (`String(parseInt(...))`, so `01001`
    // is a width, not a count) is a column count.
    const compact = records.replace(/ /g, '');
    if (compact === String(parseInt(compact, 10))) {
        const count = parseInt(compact, 10) > maximumTableSpan ? String(maximumTableSpan) : compact;
        return parseColspecs.call(this, count, ...rest);
    }
    if (!compact) return [];
    const separator = compact.includes(',') ? ',' : ';';
    const columns = [];
    let start = 0;
    while (columns.length < maximumTableSpan) {
        const end = compact.indexOf(separator, start);
        const record = compact.slice(start, end < 0 ? compact.length : end);
        const match = record.match(ColumnSpecRx);
        if (match) {
            // An explicit repeat keeps a lone width (or an empty field) in spec mode when parsed on its own.
            const repeat = match[1];
            const remaining = maximumTableSpan - columns.length;
            const count = repeat ? Math.min(parseInt(repeat, 10), remaining) : 1;
            const spec = repeat ? record.slice(repeat.length + 1) : record;
            columns.push(...parseColspecs.call(this, count + '*' + spec, ...rest));
        }
        if (end < 0) break;
        start = end + 1;
    }
    return columns;
};

const quoted = Html5Converter.prototype.convert_inline_quoted;
Html5Converter.prototype.convert_inline_quoted = function (node) {
    if (node.type === 'latexmath' || node.type === 'asciimath') {
        return `<span data-adoc-math="${node.type}">${node.text}</span>`;
    }
    return quoted.call(this, node);
};

async function documentParts(source) {
    const document = await load(source, {
        safe: 'secure', standalone: false, backend: 'html5',
        attributes: { showtitle: '', 'sectanchors!': '', 'icons!': '', 'source-highlighter!': '', lang: 'und@' }
    });
    return {
        html: await document.convert(),
        author: document.getAuthors().map(author => author.getName()).join(', '),
        revision: [document.getRevisionNumber(), document.getRevisionDate(), document.getRevisionRemark()]
            .filter(Boolean).join(', '),
        language: document.getAttribute('lang')
    };
}

// JSContext drains native Promise jobs before returning to Swift. No event loop,
// timers, or asynchronous host functions participate in secure string conversion.
function surimonoConvert(source) {
    const result = {};
    documentParts(source).then(parts => Object.assign(result, parts), () => { result.failed = true; });
    return result;
}

// The secure parser measures attribute values in UTF-8 bytes. JavaScriptCore provides
// typed arrays and URI codecs but no browser Encoding API.
class TextEncoder {
    encode(value) {
        const bytes = unescape(encodeURIComponent(value.toWellFormed()));
        return Uint8Array.from(bytes, c => c.charCodeAt(0));
    }
}
class TextDecoder {
    decode(bytes) {
        return decodeURIComponent(Array.from(bytes, b => '%' + b.toString(16).padStart(2, '0')).join(''));
    }
}
