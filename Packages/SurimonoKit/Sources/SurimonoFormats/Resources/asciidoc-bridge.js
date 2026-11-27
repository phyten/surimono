// The browser build has no filesystem bindings. Keep its parser and HTML backend,
// adapting the result for the print styles and reading settings.
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

// One conversion per context. Record only entries the parser consumed in the outer document.
const readingFields = ['sectnums', 'sectnumlevels', 'toc', 'toclevels'];
let readingLines, headerEnd, candidates, entries, regionalNumbers, readingEdits, contentsTitle;
function beginReading(source) {
    readingLines = source.replace(/^\uFEFF/, '').split(/\r\n|\r|\n/);
    entries = {};
    candidates = new Set();
    regionalNumbers = undefined;
    contentsTitle = undefined;
    readingEdits = {};
    scanHeader(0);
}

function scanHeader(start) {
    // With a missing blank line the native reader can consume a block delimiter as an
    // author or revision. It can also skip blank lines in a titleless header.
    let hasContent = start > 0, comment;
    for (headerEnd = start; headerEnd < readingLines.length; headerEnd++) {
        const line = readingLines[headerEnd].trimEnd();
        if (comment) {
            if (line === comment) comment = undefined;
        } else if (/^\/{4,}$/.test(line)) {
            comment = line;
        } else if (line.startsWith('//')) {
            continue;
        } else if (!line || /^(?:-{2,}|\.{4,}|\+{4,}|={4,}|\*{4,}|_{4,}|[|,:!]={3,})$/.test(line)) {
            if (hasContent || line) break;
        } else {
            hasContent = true;
            if (line.startsWith(':')) candidates.add(headerEnd + 1);
        }
    }
}

// The parser enters header metadata just after consuming the actual document title.
// If its underline stopped our block guard, resume at the parser's next source line.
const parseHeaderMetadata = Parser.parseHeaderMetadata;
Parser.parseHeaderMetadata = function(reader, doc, ...args) {
    const underline = reader.lineno - 2; // The reader counts lines from one and is past the title.
    if (doc && !doc.parentDocument && underline === headerEnd && readingLines?.[underline]?.trim()) {
        scanHeader(underline + 1);
    }
    return parseHeaderMetadata.call(this, reader, doc, ...args);
};

function validReadingValue(key, value, unset) {
    if (unset) return value === '' && (key === 'sectnums' || key === 'toc');
    switch (key) {
        case 'sectnums': return ['', 'all'].includes(value);
        case 'toc': return ['', 'auto', 'left', 'right', 'preamble'].includes(value);
        default: return /^\d+$/.test(value) && Number(value) <= 5;
    }
}

const storeReadingEntry = Parser.storeAttribute;
Parser.storeAttribute = function(name, value, doc, attrs, opts) {
    const result = storeReadingEntry.apply(this, arguments);
    const key = result[0];
    if (!readingLines || !doc || doc.parentDocument || !readingFields.includes(key)) return result;
    const line = opts?.sourceLocation?.lineno;
    const match = readingLines[line - 1]?.trimEnd().match(/^:(!?[\w-]+!?):(?:[ \t]+(.*))?$/);
    const rawValue = match?.[2] ?? '';
    const unset = name.startsWith('!') || name.endsWith('!');
    const literal = match && match[1] === name && [key, '!' + key, key + '!'].includes(name.toLowerCase())
        && rawValue === value;
    if (doc._headerAttributes || line > headerEnd) {
        if ((doc._headerAttributes || !readingLines[headerEnd]?.trim()) && key === 'sectnums' && literal
                && validReadingValue(key, rawValue, unset)) regionalNumbers ??= match[0];
        if (!doc._headerAttributes) delete entries[key];
        return result;
    }
    // The last assignment wins, including an alias, expansion or unreadable assignment:
    // never keep a reason from an earlier line after its value has been replaced.
    delete entries[key];
    if (!literal || !candidates.has(line)) return result;
    if (validReadingValue(key, rawValue, unset)) entries[key] = {line, value: unset ? undefined : rawValue};
    return result;
};

const finishHeader = Document.prototype.finalizeHeader;
Document.prototype.finalizeHeader = function(...args) {
    if (this.parentDocument || typeof surimonoReadingHeader !== 'function') return finishHeader.apply(this, args);
    const attrs = this.attributes;
    const positions = {};
    for (const [key, entry] of Object.entries(entries)) {
        if (attrs[key] === entry.value) positions[key] = entry.line;
    }
    // toc2 and explicit placement can supersede the spelling of toc itself.
    if ('toc2' in attrs || attrs['toc-placement'] !== 'auto' || attrs['toc-position']) delete positions.toc;
    const values = Object.fromEntries(readingFields.filter(key => key in attrs).map(key => [key, attrs[key]]));
    if (this._attributesModified.has('toc-title')) contentsTitle = attrs['toc-title'];
    const result = finishHeader.apply(this, args);
    const lead = 'toc' in attrs && attrs['toc-placement'] !== 'macro';
    if (!lead && 'toc' in attrs) delete positions.toc;
    readingEdits = surimonoReadingHeader(positions, values, lead);
    // Change the initial numbering only. Asciidoctor still owns per-section switches and
    // appendix, part and chapter ordinals. Its saved snapshot is replayed before conversion.
    for (const snapshot of [attrs, this._headerAttributes]) {
        if (readingEdits.sectnums === 0) delete snapshot.sectnums;
        if (readingEdits.sectnums === 1) snapshot.sectnums ??= '';
        if (readingEdits.sectnumlevels != null) snapshot.sectnumlevels = String(readingEdits.sectnumlevels);
    }
    return result;
};

const nativeSectionLabel = Section.prototype.sectnum;
Section.prototype.sectnum = function(delimiter = '.', append = null) {
    if (typeof surimonoSectionLabel !== 'function') return nativeSectionLabel.apply(this, arguments);
    const ordinals = [];
    let section = this;
    do {
        ordinals.push(section.numeral ?? '');
        if (section.level <= 1) break;
        section = section.getParent();
    } while (section instanceof Section);
    const suffix = append === false ? '' : append ?? delimiter;
    return surimonoSectionLabel(ordinals.reverse(), String(delimiter), String(suffix));
};

// A reference and a TOC can appear on either side of a body attribute change.
// Number them at the target section's depth, after the parser assigns its native ordinals.
const beyondNumberDepth = new Set();
const initializeSection = Parser.initializeSection;
Parser.initializeSection = async function(reader, parent, attributes) {
    const depth = toInt(parent.document.attributes.sectnumlevels ?? 3);
    const section = await initializeSection.call(this, reader, parent, attributes);
    if (!(section.level <= depth)) beyondNumberDepth.add(section);
    return section;
};

const nativeSectionReference = Section.prototype.xreftext;
Section.prototype.xreftext = function(style) {
    if (!this.caption && beyondNumberDepth.has(this)) style = null;
    return nativeSectionReference.call(this, style);
};

async function documentParts(source, contentsDepth) {
    beginReading(source);
    beyondNumberDepth.clear();
    const document = await load(source, {
        safe: 'secure', standalone: false, backend: 'html5',
        attributes: { showtitle: '', 'sectanchors!': '', 'icons!': '', 'source-highlighter!': '', lang: 'und@' }
    });
    for (const section of beyondNumberDepth) {
        if (!section.caption) section.numbered = false;
    }
    const macro = document.getAttribute('toc-placement') === 'macro';
    const lead = document.hasAttribute('toc') && !macro;
    const hasMacro = document.hasAttribute('toc') && document.findBy({context: 'toc'}).length > 0;
    const combined = lead && document.hasSections() && hasMacro;
    const fileDepth = document.getAttribute('toclevels');
    const leadDepth = readingEdits.toclevels ?? (fileDepth == null ? contentsDepth : null);
    const depthForOutline = depth => document.isMultipart() ? depth : Math.max(1, depth);
    const outline = document.converter.convert_outline;
    document.converter.convert_outline = function(node, options) {
        // Automatic and preamble lists omit options. A toc macro passes its own options,
        // even when empty, so its outline can read the attributes at that position.
        if (lead && node === document && options == null && leadDepth != null) {
            options = {toclevels: depthForOutline(leadDepth)};
        }
        return outline.call(this, node, {...options, sectnumlevels: Infinity});
    };
    if (lead && readingEdits.toc === 0) {
        document.setAttribute('toc-placement', 'macro');
    } else if (lead && readingEdits.separatePage && document.hasAttribute('toc-placement', 'preamble')) {
        document.setAttribute('toc-placement', 'auto');
    }
    // The embedded converter normally discards macro nodes when it also writes an automatic contents.
    // Render each such node with its own title and levels at its original position in the unified finish.
    if (combined && (contentsDepth != null || readingEdits.toc != null || readingEdits.toclevels != null)) {
        const convertToc = document.converter.convert_toc;
        document.converter.convert_toc = async function(node) {
            const placement = document.attributes['toc-placement'];
            document.attributes['toc-placement'] = 'macro';
            try {
                let toc = await convertToc.call(this, node);
                if (node.id == null) {
                    toc = toc.replace('<div id="toc" ', '<div ').replace('<div id="toctitle" ', '<div ');
                }
                return toc.replace('<div ', '<div data-surimono-in-text="1" ');
            } finally {
                document.attributes['toc-placement'] = placement;
            }
        };
    }
    let addedLead = '';
    if (!lead && readingEdits.addedLeadDepth != null && document.hasSections()) {
        // A generated lead still needs link targets when the manuscript disables automatic IDs.
        let nextID = 0;
        const missingTargets = document.findBy({context: 'section'}, section => section !== document.header && !section.id);
        for (const section of missingTargets) {
            let id;
            do { id = 'surimono-heading-' + ++nextID; } while (id in document.catalog.refs);
            section.id = id;
            await section.precomputeTitle();
        }
        const list = await document.converter.convert(document, 'outline', {
            toclevels: depthForOutline(readingEdits.addedLeadDepth)
        });
        const title = contentsTitle == null ? '' : '<div class="title">' + contentsTitle + '</div>';
        addedLead = '<div class="toc">' + title + list + '</div>';
    }
    const html = addedLead + await document.convert();
    return {
        combinedContents: String(combined),
        leadContents: String((lead && readingEdits.toc !== 0) || addedLead !== ''),
        hasContentsMacro: String(hasMacro && (macro || combined)),
        regionalNumbers,
        contentsTitle,
        html,
        author: document.getAuthors().map(author => author.getName()).join(', '),
        revision: [document.getRevisionNumber(), document.getRevisionDate(), document.getRevisionRemark()]
            .filter(Boolean).join(', '),
        language: document.getAttribute('lang')
    };
}

// JSContext drains native Promise jobs before returning to Swift. No event loop,
// timers, or asynchronous host functions participate in secure string conversion.
function surimonoConvert(source, contentsDepth) {
    const result = {};
    documentParts(source, contentsDepth).then(parts => Object.assign(result, parts), () => { result.failed = true; });
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
