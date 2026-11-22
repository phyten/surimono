import Foundation

extension BeamerOverlay {
    indirect enum Part {
        case text(String)
        case group([Part])
        case environment(String, String?, String?, [Part])
        case choice(String, String, [[Part]])
        case declaration(String, String)
        case pause(Int?)
        case item(String?, String?)
    }

    final class Parser {
        let input: [Character]
        var index = 0
        var unreadable = false

        init(_ source: String) { input = Array(source) }

        func sequence(environment: String? = nil, group: Bool = false, depth: Int = 0) -> [Part] {
            guard depth <= LaTeXDocument.maximumDepth, StackSpace.hasRoom else {
                unreadable = true
                let suffix = String(input[index...])
                index = input.count
                return [.text(suffix)]
            }
            var parts: [Part] = []
            var text = ""
            func flush() {
                if !text.isEmpty {
                    parts.append(.text(text))
                    text = ""
                }
            }
            while index < input.count {
                let start = index
                if let end = LaTeXLexer.opaqueEnd(input, at: start) {
                    text += input[start..<end]
                    index = end
                } else if input[index] == "}", group {
                    index += 1
                    break
                } else if input[index] == "{" {
                    flush()
                    index += 1
                    parts.append(.group(sequence(group: true, depth: depth + 1)))
                } else if input[index] == "\\" {
                    index += 1
                    guard let command = LaTeXLexer.word(input, at: index) else {
                        index = min(index + 1, input.count)
                        text += input[start..<index]
                        continue
                    }
                    index += command.count
                    if command == "end", let name = delimited("{", "}") {
                        if name == environment { break }
                    } else if command == "begin", let name = delimited("{", "}") {
                        flush()
                        var spec = angle()
                        var option: String?
                        var leading: [Part] = []
                        if Self.lists.contains(name) || name == "overprint" {
                            option = delimited("[", "]")
                        } else if Self.blocks.contains(name), let title = argument(depth: depth) {
                            leading = [.group(title)]
                            if spec == nil { spec = angle() }
                        }
                        let body = sequence(environment: name, depth: depth + 1)
                        parts.append(.environment(name, option, spec, leading + body))
                        continue
                    } else if let part = control(command, depth: depth) {
                        flush()
                        parts.append(part)
                        continue
                    }
                    text += input[start..<index]
                } else {
                    text.append(input[index])
                    index += 1
                }
            }
            flush()
            return parts
        }

        static let lists = ["itemize", "enumerate", "description"]
        static let blocks = ["block", "alertblock", "exampleblock"]

        private func control(_ command: String, depth: Int) -> Part? {
            switch command {
            case "pause":
                guard let value = delimited("[", "]") else { return .pause(nil) }
                guard let step = Int(value), (0...1_000_000).contains(step) else {
                    unreadable = true
                    return .pause(nil)
                }
                return .pause(step)
            case "item":
                let spec = angle()
                let label = delimited("[", "]")
                return .item(spec ?? angle(), label)
            case "only", "uncover", "visible", "onslide", "invisible", "alt", "temporal", "alert", "structure", "mode":
                var name = command
                if name == "onslide", index < input.count {
                    if input[index] == "*" {
                        name = "only"
                        index += 1
                    } else if input[index] == "+" {
                        index += 1
                    }
                }
                var spec = angle()
                let count = name == "temporal" ? 3 : name == "alt" ? 2 : 1
                var args: [[Part]] = []
                for _ in 0..<count {
                    guard let arg = argument(depth: depth) else { break }
                    args.append(arg)
                }
                if spec == nil, !args.isEmpty { spec = angle() }
                if args.isEmpty, name == "onslide" || name == "mode" {
                    return .declaration(name, spec ?? "*")
                }
                if args.count != count { unreadable = true }
                return .choice(name, spec ?? "*", args)
            default:
                // Unknown overlay-aware macros retain their argument for the ordinary reader.
                // A bare less-than operator in prose or math is not an overlay specification.
                if index < input.count, input[index] == "<",
                    let close = input[index...].prefix(while: { $0 != "\n" && $0 != "{" && $0 != "}" }).firstIndex(
                        of: ">"),
                    close + 1 < input.count, input[close + 1] == "{"
                {
                    index = close + 1
                    unreadable = true
                    return .text("\\" + command)
                }
                return nil
            }
        }

        private func argument(depth: Int) -> [Part]? {
            let start = nextNonspace()
            guard start < input.count, input[start] == "{" else { return nil }
            index = start + 1
            return sequence(group: true, depth: depth + 1)
        }

        private func nextNonspace() -> Int {
            var start = index
            while start < input.count, input[start].isWhitespace { start += 1 }
            return start
        }

        private func angle() -> String? {
            let start = nextNonspace()
            guard start < input.count, input[start] == "<" else { return nil }
            var end = start + 1
            while end < input.count, ![">", "{", "}", "\n"].contains(input[end]) { end += 1 }
            let value = String(input[(start + 1)..<end])
            if end < input.count, input[end] == ">" {
                index = end + 1
            } else {
                unreadable = true
                index = end
            }
            return value
        }

        private func delimited(_ open: Character, _ close: Character) -> String? {
            let start = nextNonspace()
            guard start < input.count, input[start] == open else { return nil }
            var p = start + 1
            var braces = 0
            while p < input.count {
                if let end = LaTeXLexer.opaqueEnd(input, at: p) {
                    p = end
                } else if input[p] == "\\" {
                    p = min(p + 2, input.count)
                } else if input[p] == close, braces == 0 {
                    index = p + 1
                    return String(input[(start + 1)..<p])
                } else {
                    if input[p] == "{" { braces += 1 }
                    if input[p] == "}" { braces = max(0, braces - 1) }
                    p += 1
                }
            }
            return nil
        }
    }
}
