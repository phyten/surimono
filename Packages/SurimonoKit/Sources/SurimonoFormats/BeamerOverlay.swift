import Foundation

/// Compiles a frame into ordinary reader input. Only material with a top-level slide number
/// is repeated; inline math, verbatim and macros still use the document's normal reader.
enum BeamerOverlay {
    struct Result {
        let pages: [String]
        let hasUnreadableSpecification: Bool
    }

    static func evaluate(
        _ source: String, handout: Bool, defaultSpecification: String? = nil, frameSpecification: String? = nil
    ) -> Result {
        let parser = Parser(source)
        let parts = parser.sequence()
        let listSpec = defaultSpecification.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
        func page(_ step: Int, all: Bool = false) -> (String?, Execution) {
            let execution = Execution(step: step, handout: handout, all: all)
            if let frameSpecification, !execution.selection(frameSpecification).active && !all {
                return (nil, execution)
            }
            return (execution.render(parts, itemSpec: listSpec), execution)
        }
        func fullFrame() -> Result {
            Result(pages: [page(1, all: true).0 ?? source], hasUnreadableSpecification: true)
        }
        if parser.unreadable { return fullFrame() }
        var step = 1
        var pages: [String] = []
        var keepSteps = false
        var lastStep = 1
        var total = 0
        while true {
            let (text, execution) = page(step)
            if execution.unreadable { return fullFrame() }
            if handout { return Result(pages: text.map { [$0] } ?? [], hasUnreadableSpecification: false) }
            lastStep = max(lastStep, execution.lastStep)
            if !keepSteps, execution.keepsSteps {
                keepSteps = true
                // A previously absent branch can reveal a swap. Replay earlier steps in order.
                if step > 1 {
                    step = 1
                    continue
                }
            }
            if keepSteps {
                total += text?.utf8.count ?? 0
                // Large numeric specifications must not expand a small input into an unbounded PDF.
                guard lastStep <= 512, total <= 8_000_000, lastStep <= 8_000_000 / max(1, source.utf8.count)
                else { return fullFrame() }
                if let text { pages.append(text) }
            }
            if step >= lastStep {
                return Result(pages: keepSteps ? pages : text.map { [$0] } ?? [], hasUnreadableSpecification: false)
            }
            step = keepSteps ? step + 1 : lastStep
        }
    }

    private enum Visibility { case shown, covered, absent }

    private final class Execution {
        let step: Int
        let handout: Bool
        let all: Bool
        var pause = 1
        var lastStep = 1
        var keepsSteps = false
        var unreadable = false

        init(step: Int, handout: Bool, all: Bool) {
            self.step = step
            self.handout = handout
            self.all = all
        }

        func selection(_ source: String) -> (active: Bool, future: Bool) {
            guard let spec = BeamerOverlaySpecification.decode(source, handout: handout, pause: &pause) else {
                unreadable = true
                return (true, false)
            }
            lastStep = max(lastStep, spec.lastStep)
            keepsSteps = keepsSteps || spec.bounded
            // A printed handout has a single frame page. Include each positive handout step,
            // respecting explicit exclusions such as handout:0 and mode-only selections.
            let active =
                handout ? spec.intervals.contains { ($0.last ?? Int.max) >= max(1, $0.first) } : spec.contains(step)
            return (all || active, !all && spec.lastStep > step)
        }

        func render(_ parts: [Part], itemSpec: String?, overprint: Bool = false) -> String {
            var result = ""
            var buffer = ""
            var visibility = Visibility.shown
            var isOverprintPart = false
            var coveredItem = false
            var activeMode = true
            func flush() {
                guard !buffer.isEmpty else { return }
                if isOverprintPart && !handout && !all {
                    let env = visibility == .shown ? "surimonooverprintpart" : "surimonooverprintcovered"
                    result += "\\begin{\(env)}" + buffer + "\\end{\(env)}"
                } else if visibility == .shown || all {
                    result += buffer
                } else if visibility == .covered, !coveredItem {
                    result += Self.cover(buffer)
                } else if visibility == .covered {
                    result += buffer
                }
                buffer = ""
            }
            for part in parts {
                if case .declaration("mode", let spec) = part {
                    flush()
                    activeMode = selection(spec).active
                    continue
                }
                guard activeMode else { continue }
                switch part {
                case .pause(let number):
                    flush()
                    pause = number ?? (pause + 1)
                    lastStep = max(lastStep, pause)
                    visibility = all || handout || step >= pause ? .shown : .covered
                    coveredItem = false
                case .declaration(let name, let spec):
                    flush()
                    let active = selection(spec).active
                    visibility = active ? .shown : .covered
                    isOverprintPart = overprint && name == "onslide"
                    if isOverprintPart && handout && !active { visibility = .absent }
                    coveredItem = false
                case .item(let spec, let label):
                    flush()
                    let active = selection(spec ?? itemSpec ?? "*").active
                    if visibility != .absent || all {
                        result += "\\item" + (label.map { "[" + $0 + "]" } ?? "")
                        coveredItem = !all && (visibility == .covered || !active)
                        if coveredItem { result += "\\surimonocovereditem{}" } else if label == nil { result += " " }
                    }
                case .text(let text):
                    buffer += text
                case .group(let body):
                    buffer += "{" + render(body, itemSpec: itemSpec) + "}"
                case .choice(let name, let source, let arguments):
                    buffer += choice(name, source, arguments, itemSpec: itemSpec)
                case .environment(let name, let option, let source, let parts):
                    buffer += environment(name, option, source, parts, itemSpec: itemSpec)
                }
            }
            flush()
            return result
        }

        private static func cover(_ source: String) -> String {
            source.isEmpty || source.allSatisfy(\.isWhitespace) ? source : "\\surimonocovered{" + source + "}"
        }

        private func choice(_ name: String, _ spec: String, _ args: [[Part]], itemSpec: String?) -> String {
            let match = selection(spec)
            switch name {
            case "alt", "temporal":
                keepsSteps = true
                if all { return args.map { render($0, itemSpec: itemSpec) }.joined(separator: " ") }
                let index = name == "alt" ? (match.active ? 0 : 1) : (match.active ? 1 : match.future ? 0 : 2)
                return args.indices.contains(index) ? render(args[index], itemSpec: itemSpec) : ""
            case "only", "mode":
                if !match.active { return "" }
            default: break
            }
            guard let first = args.first else { return "" }
            let content = render(first, itemSpec: itemSpec)
            switch name {
            case "alert", "structure":
                return match.active ? "\\" + name + "{" + content + "}" : content
            case "invisible":
                keepsSteps = true
                return match.active && !all ? Self.cover(content) : content
            default: return match.active ? content : Self.cover(content)
            }
        }

        private func environment(
            _ name: String, _ option: String?, _ spec: String?, _ parts: [Part], itemSpec: String?
        ) -> String {
            let active = selection(spec ?? "*").active
            var nestedSpec = itemSpec
            var headerOption = option.map { "[" + $0 + "]" } ?? ""
            if Parser.lists.contains(name), let option, option.first == "<", option.last == ">" {
                nestedSpec = String(option.dropFirst().dropLast())
                headerOption = ""
            }
            switch name {
            case "onlyenv", "overprint", "invisibleenv": keepsSteps = true
            default: break
            }
            if name == "onlyenv" && !active { return "" }
            let body = render(parts, itemSpec: nestedSpec, overprint: name == "overprint")
            switch name {
            case "onlyenv": return body
            case "invisibleenv": return active && !all ? Self.cover(body) : body
            case "visibleenv", "uncoverenv", "actionenv": return active ? body : Self.cover(body)
            case "overprint" where all || handout: return body
            default:
                let content = "\\begin{\(name)}" + headerOption + body + "\\end{\(name)}"
                return active ? content : Self.cover(content)
            }
        }
    }
}
