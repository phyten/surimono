import Foundation
import WebKit
import os

@MainActor
enum DiagramScript {
    static let probe = "return document.querySelector('.graphviz-block,.plantuml-block') ? 'yes' : 'no';"
    static let fallback = """
        for (const source of document.querySelectorAll('.graphviz-block > .diagram-source,.plantuml-block > .diagram-source')) {
          const block = source.parentElement;
          block.classList.add('diagram-error');
          if (!block.querySelector('.diagram-message')) {
            const message = document.createElement('div');
            message.className = 'diagram-message';
            message.textContent = 'Diagram engine unavailable or timed out';
            block.prepend(message);
          }
        }
        """
    static let viz = library("viz-global")
    static let plantuml = library("plantuml")
    private static let renderer = library("diagrams") ?? ""

    private static func library(_ name: String) -> String? {
        Bundle.module.url(forResource: name, withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    /// The upstream build resolves its own file name against the document's base URL, only to locate files it never
    /// loads (the WebAssembly is inlined). A document without a base URL makes that throw, so the lookup is replaced.
    static func vizLoading(_ source: String) -> String? {
        let lookup = #"new URL("viz-global.js",document.baseURI).href"#
        guard source.components(separatedBy: lookup).count == 2 else { return nil }
        return source.replacingOccurrences(of: lookup, with: #""about:blank""#)
            + "\n;globalThis.surimonoViz = await globalThis.Viz.instance();"
            + "globalThis.PLANTUML_VIZ = {instance: () => Promise.resolve(globalThis.surimonoViz)};"
    }

    /// The upstream ES module has no imports and one export clause. Capture those exports in a private closure;
    /// do not use file URL module imports (which need page-world execution and different WebKit permissions).
    static func plantUMLLoading(_ source: String) -> String? {
        let exports = "export{C as render,D as renderToString};"
        // The published file ends at the export clause with no newline; an editor may add one.
        guard source.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(exports),
            source.components(separatedBy: exports).count == 2
        else { return nil }
        return "globalThis.surimonoPlantUML = (() => {\n"
            + source.replacingOccurrences(of: exports, with: "return {render: C, renderToString: D};") + "\n})();"
    }

    /// A single preparation entry point for printing, exporting and live palette samples. The evaluator supplies
    /// the caller's timeout and retained isolated world; no script elements are ever added to the document.
    static func prepare(
        in webView: WKWebView, height: Double, evaluate: (String) async throws -> String?
    ) async throws {
        guard try await evaluate(probe) == "yes" else { return }
        let deadline = ContinuousClock.now + .seconds(10)
        do {
            try await MermaidScript.preventResourceLoads(in: webView)
            _ = try await evaluate(fallback)
            if try await evaluate("return globalThis.surimonoViz ? 'yes' : 'no';") != "yes" {
                guard let viz, let loading = vizLoading(viz) else { return }
                let start = ContinuousClock.now
                _ = try await evaluate(loading)
                log(start: start, engine: 0, phase: 0)
            }
            if try await evaluate("return document.querySelector('.plantuml-block') ? 'yes' : 'no';") == "yes",
                try await evaluate("return globalThis.surimonoPlantUML ? 'yes' : 'no';") != "yes"
            {
                guard let plantuml, let loading = plantUMLLoading(plantuml) else { return }
                let start = ContinuousClock.now
                // Declining by callback (not by returning false) prevents upstream's script-tag fallback.
                _ = try await evaluate(
                    """
                    globalThis.PLANTUML_STDLIB_LOADER = (url, ok, err) => { err('Unavailable offline'); return true; };
                    globalThis.PLANTUML_FILE_LOADER = (path, from, ok, err) => { err('Unavailable offline'); };
                    \(loading)
                    """)
                log(start: start, engine: 1, phase: 0)
            }
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let budget = max(0, Double(remaining.seconds) * 1000 + Double(remaining.attoseconds) / 1e15)
            let result = try await evaluate(
                "const pageHeight = \(max(1, height)); const budget = \(budget);\n" + renderer)
            #if DEBUG
                if let result, let data = result.data(using: .utf8),
                    let times = try? JSONSerialization.jsonObject(with: data) as? [[Double]]
                {
                    for time in times where time.count == 2 {
                        Logger(subsystem: "io.github.phyten.Surimono", category: "Diagrams")
                            .debug("\(time[0]) 1 \(time[1])")
                    }
                }
            #endif
        } catch {
            try Task.checkCancellation()
            _ = try await evaluate(fallback)
        }
    }

    private static func log(start: ContinuousClock.Instant, engine: Int, phase: Int) {
        #if DEBUG
            let elapsed = start.duration(to: .now).components
            let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            // Numeric fields: engine (0 Viz, 1 PlantUML), phase (0 load, 1 render), elapsed milliseconds.
            Logger(subsystem: "io.github.phyten.Surimono", category: "Diagrams")
                .debug("\(engine) \(phase) \(milliseconds)")
        #endif
    }
}
