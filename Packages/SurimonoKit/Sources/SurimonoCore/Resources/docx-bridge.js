const wordStyles = [
    "u => u", "strike => s", "highlight => mark", "br[type='page'] => br.page-break",
    "r[style-name='Verbatim Char'] => code", "r[style-name='Code'] => code", "r[style-name='Source Code'] => code",
    "comment-reference => !"
];
for (const [names, path] of [
    [["Title", "表題", "タイトル"], "header.org-title-block > h1.org-title:fresh"],
    [["Subtitle", "副題"], "header.org-title-block > p.org-subtitle:fresh"],
    [["Author", "作成者"], "header.org-title-block > p.org-author:fresh"],
    [["Date", "日付"], "header.org-title-block > p.org-date:fresh"],
    [["Quote", "引用文", "引用", "Intense Quote", "強調引用文", "強調引用", "Block Text"], "blockquote > p:fresh"],
    [["Caption", "図表番号"], "p.docx-caption:fresh"],
    [["Code", "Source Code", "HTML Preformatted"], "pre:fresh > code"],
    [["Abstract", "要約"], "p.abstract:fresh"]
]) {
    for (const name of names) wordStyles.push("p[style-name='" + name + "'] => " + path);
}
for (let level = 1; level <= 6; level++) {
    for (const name of ["見出し " + level, "見出し" + level])
        wordStyles.push("p[style-name='" + name + "'] => h" + level + ":fresh");
}
// Match list properties ahead of the generic List Paragraph style, including all nine Word levels.
for (let level = 1; level <= 9; level++) {
    const parents = "ul|ol > li > ".repeat(level - 1);
    wordStyles.push("p:ordered-list(" + level + ") => " + parents + "ol > li:fresh",
                    "p:unordered-list(" + level + ") => " + parents + "ul > li:fresh");
}
wordStyles.push("p[style-name='List Paragraph'] => p:fresh", "p[style-name='リスト段落'] => p:fresh");

var wordResult;
function startWord(bytes) {
    wordResult = null;
    module.exports.convertToHtml({arrayBuffer: bytes.buffer}, {
        styleMap: wordStyles, includeEmbeddedStyleMap: false, externalFileAccess: false
    }).then(result => { wordResult = {html: result.value, warnings: result.messages.length}; },
            () => { wordResult = {failed: true}; });
}
