function surimonoConvert(source) {
    const djot = module.exports;
    const html = djot.renderHTML(djot.parse(source), {overrides: {
        // Print themes and the outline expect heading anchors on the headings themselves.
        section(node, renderer) {
            const heading = node.children[0];
            if (heading?.tag !== "heading") return renderer.renderAstNodeDefault(node);
            heading.attributes = {...node.attributes, ...heading.attributes};
            if (!heading.attributes.id && node.autoAttributes?.id) {
                heading.attributes["data-djot-auto"] = node.autoAttributes.id;
            }
            return renderer.renderChildren(node);
        },
        div(node, renderer) {
            return renderer.inTags("div", node, 2, {"data-djot-div": ""});
        },
        inline_math: math,
        display_math: math,
        symb(node, renderer) {
            return renderer.renderTag("span", node, {"data-djot-symbol": ""}) + renderer.escape(node.alias) + '</span>';
        }
    }});
    return {html};
}

function math(node, renderer) {
    return renderer.renderTag("span", node, {"data-djot-math": node.tag}) + renderer.escape(node.text) + "</span>";
}
