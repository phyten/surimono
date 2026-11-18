enum MermaidBlock {
    static func html(_ source: String) -> String {
        "<div class=\"mermaid-block\"><pre class=\"mermaid-source\">\(HTML.escape(source))</pre></div>\n"
    }
}
