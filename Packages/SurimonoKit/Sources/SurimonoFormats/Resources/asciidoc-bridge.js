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
