import Foundation

struct TikZScope {
    var values: [String: Any] = [:]
    var definitions: [String: String] = [:]
    /// `level distance` and `sibling distance` only steer the child layout of a tree, so they stay
    /// out of the node and path styles that reach the painter.
    var tree = ["level distance": "15mm", "sibling distance": "15mm"]
}

extension TikZParser {
    static let directions = [
        "above", "below", "left", "right", "above right", "above left", "below right", "below left",
    ]
    static let anchors = [
        "center", "base", "east", "west", "south", "north", "north east", "north west", "south east", "south west",
    ]
    static let widths = [
        "ultra thin": "0.1pt", "very thin": "0.2pt", "thin": "0.4pt", "semithick": "0.6pt",
        "thick": "0.8pt", "very thick": "1.2pt", "ultra thick": "1.6pt",
    ]
    static let fonts: Set<String> = [
        "tiny", "scriptsize", "footnotesize", "small", "normalsize", "large", "Large", "LARGE", "huge", "Huge",
        "bfseries", "mdseries", "itshape", "slshape", "upshape", "sffamily", "rmfamily", "ttfamily",
    ]

    func length(_ source: String, variable: Double? = nil) throws -> String {
        let raw = source.tikzUnbraced
        let unit = ["cm", "mm", "pt", "bp", "em", "ex", "in", "pc"].first { raw.hasSuffix($0) } ?? ""
        let number = String(raw.dropLast(unit.count)).tikzTrimmed
        let value = try scalar(number, variable: variable)
        return tikzNumber(value) + unit
    }

    func scalar(_ raw: String, variable: Double? = nil) throws -> Double {
        guard raw.utf8.count <= 512 else { throw TikZError("expression") }
        if let value = Double(raw), value.isFinite, abs(value) <= 1e9 { return value }
        guard let value = try? PGFMath.evaluate(raw.tikzUnbraced, x: variable), value.isFinite, abs(value) <= 1e9
        else { throw TikZError(raw) }
        return value
    }

    func normalizedAnchor(_ anchor: String) throws -> String {
        if Self.anchors.contains(anchor) { return anchor }
        return tikzNumber(try scalar(anchor))
    }

    func tikzNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    func style(_ options: String, scope: TikZScope, kind: String) throws -> [String: Any] {
        var state = scope
        if ["path", "draw", "fill", "filldraw", "clip", "node", "coordinate"].contains(kind),
            let every = scope.definitions["every path"]
        {
            try apply(every, to: &state, kind: kind)
        }
        if kind == "node", let every = scope.definitions["every node"] {
            try apply(every, to: &state, kind: kind)
        }
        if ["draw", "filldraw"].contains(kind), state.values["draw"] == nil || state.values["draw"] as? String == "none"
        {
            state.values["draw"] = "currentColor"
        }
        if ["fill", "filldraw"].contains(kind), state.values["fill"] == nil || state.values["fill"] as? String == "none"
        {
            state.values["fill"] = "currentColor"
        }
        try apply(options, to: &state, kind: kind)
        for key in ["draw", "fill"] {
            if state.values[key] as? String == "currentColor" {
                state.values[key] = state.values["color"] ?? "#000000"
            } else if state.values[key] == nil {
                state.values[key] = "none"
            }
        }
        return state.values
    }

    func apply(_ options: String, to state: inout TikZScope, kind: String, depth: Int = 0) throws {
        guard depth < 24, options.utf8.count <= work else { throw TikZError("style limit") }
        work -= options.utf8.count
        var unsupported: [String] = []
        for item in try TikZScanner.split(options, at: ",") where !item.isEmpty {
            // '=' in an arrow-tip argument belongs to the tip. Only a top-level '=' starts a key value.
            let parts = try TikZScanner.split(item, at: "=")
            let key = parts[0]
            let assigned = parts.count > 1
            let value = parts.dropFirst().joined(separator: "=").tikzUnbraced
            func bare() throws {
                guard !assigned else { throw TikZError(key) }
            }
            func oneOf(_ choices: [String]) throws -> String {
                guard choices.contains(value) else { throw TikZError(item) }
                return value
            }
            // Path geometry, node placement and the to-path handler each consume different keys.
            // A known key in the wrong handler is as unsafe as an unknown one.
            let nodeOnly = [
                "shape", "rectangle", "circle", "ellipse", "diamond", "align", "anchor",
                "minimum width", "minimum height", "minimum size", "inner sep", "outer sep",
                "text width", "midway", "near start", "near end", "pos", "sloped",
            ]
            if nodeOnly.contains(key), kind != "node", kind != "scope" { throw TikZError(key) }
            if kind == "to", !["in", "out", "bend left", "bend right"].contains(key) { throw TikZError(key) }
            if kind == "coordinate", key != "x", key != "y",
                !["xshift", "yshift", "shift", "rotate", "scale", "xscale", "yscale"].contains(key)
            {
                throw TikZError(key)
            }
            if kind == "node", ["scale", "xscale", "yscale", "shift", "xshift", "yshift"].contains(key) {
                throw TikZError(key)
            }
            if let suffix = ["/.append style", "/.style"].first(where: { key.hasSuffix($0) }) {
                guard kind == "scope", assigned else { throw TikZError(key) }
                let name = String(key.dropLast(suffix.count)).tikzTrimmed
                guard !name.isEmpty, !name.contains("/") else { throw TikZError(key) }
                if suffix == "/.append style", let previous = state.definitions[name] {
                    guard previous.utf8.count + value.utf8.count < 100_000 else { throw TikZError(key) }
                    state.definitions[name] = previous + "," + value
                } else {
                    state.definitions[name] = value
                }
            } else if let definition = state.definitions[key] {
                guard assigned == definition.contains("#1") else { throw TikZError(key) }
                let occurrences = definition.components(separatedBy: "#1").count - 1
                guard occurrences == 0 || value.utf8.count <= work / occurrences else { throw TikZError("style limit") }
                try apply(
                    definition.replacingOccurrences(of: "#1", with: value), to: &state, kind: kind, depth: depth + 1)
            } else if let width = Self.widths[key] {
                try bare()
                state.values["line width"] = width
            } else if Self.directions.contains(key) {
                guard kind == "node" else { throw TikZError(key) }
                guard state.values["anchor"] == nil else { throw TikZError("anchor with " + key) }
                var tokens = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                if let of = tokens.firstIndex(of: "of") {
                    guard of + 2 == tokens.count, let reference = tokens.last else { throw TikZError(item) }
                    _ = try named(reference)
                    tokens = Array(tokens.prefix(of))
                }
                if !tokens.isEmpty { try distances(tokens.joined(separator: " ")) }
                for direction in Self.directions { state.values.removeValue(forKey: direction) }
                state.values[key] = value
            } else if !assigned, let color = LaTeXSymbols.cssColor(key, defined: colors) {
                setColor(color, in: &state)
            } else if ["->", "<-", "<->", "|-|", "-"].contains(key) || key.hasPrefix("-{") || key == "-Latex"
                || key == "-Stealth" || key == "-To"
            {
                try bare()
                state.values["arrows"] = key.hasPrefix("-") && key.count > 2 ? "->" : key
                if key.hasPrefix("-"), key.count > 2 { try tip(String(key.dropFirst()), to: &state) }
            } else {
                switch key {
                case ">": try tip(value, to: &state)
                case "draw", "fill", "text", "color":
                    if !assigned, key == "draw" || key == "fill" {
                        state.values[key] = "currentColor"
                    } else if value == "none", key == "draw" || key == "fill" {
                        state.values[key] = value
                    } else if let color = LaTeXSymbols.cssColor(value, defined: colors) {
                        if key == "color" { setColor(color, in: &state) } else { state.values[key] = color }
                    } else {
                        throw TikZError(item)
                    }
                case "solid", "dashed", "dotted", "densely dashed", "loosely dashed":
                    try bare()
                    let dashes = [
                        "solid": "", "dashed": "on 3pt off 3pt", "dotted": "on 0.4pt off 2pt",
                        "densely dashed": "on 3pt off 2pt", "loosely dashed": "on 3pt off 6pt",
                    ]
                    state.values["dash pattern"] = dashes[key]
                case "dash pattern":
                    let parts = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                    guard parts.count >= 4, parts.count.isMultiple(of: 4) else { throw TikZError(item) }
                    for i in stride(from: 0, to: parts.count, by: 2) {
                        guard parts[i] == (i.isMultiple(of: 4) ? "on" : "off") else { throw TikZError(item) }
                        _ = try length(parts[i + 1])
                    }
                    state.values[key] = value
                case "rounded corners": state.values[key] = assigned ? try length(value) : "4pt"
                case "pattern": state.values[key] = try oneOf(["north east lines"])
                case "line cap": state.values[key] = try oneOf(["butt", "round", "rect"])
                case "line join": state.values[key] = try oneOf(["miter", "round", "bevel"])
                case "line width", "minimum width", "minimum height", "minimum size", "inner sep", "outer sep",
                    "text width", "x", "y", "step":
                    state.values[key] = try length(value)
                case "font":
                    let declarations = value.replacingOccurrences(of: " ", with: "")
                    let tokens = declarations.split(separator: "\\").map(String.init)
                    guard !tokens.isEmpty, tokens.allSatisfy(Self.fonts.contains),
                        declarations == tokens.map({ "\\" + $0 }).joined()
                    else { throw TikZError(item) }
                    state.values[key] = declarations
                case "node distance":
                    try distances(value)
                    state.values[key] = value
                case "opacity", "fill opacity":
                    let opacity = try scalar(value)
                    guard (0...1).contains(opacity) else { throw TikZError(item) }
                    state.values[key] = opacity
                case "rotate" where kind == "node": state.values[key] = try scalar(value)
                case "scale", "xscale", "yscale", "rotate", "shift", "xshift", "yshift":
                    var transforms = state.values["transforms"] as? [[Any]] ?? []
                    guard transforms.count < 64 else { throw TikZError("transform limit") }
                    let operand: Any
                    switch key {
                    case "shift": operand = try coordinate(value)
                    case "xshift", "yshift": operand = try length(value)
                    default: operand = try scalar(value)
                    }
                    transforms.append([key, operand])
                    state.values["transforms"] = transforms
                case "rectangle", "circle", "ellipse", "diamond":
                    try bare()
                    state.values["shape"] = key
                case "shape": state.values[key] = try oneOf(["rectangle", "circle", "ellipse", "diamond"])
                case "anchor":
                    guard !Self.directions.contains(where: { state.values[$0] != nil }) else {
                        throw TikZError("direction with anchor")
                    }
                    state.values[key] = try normalizedAnchor(value)
                case "align": state.values[key] = try oneOf(["left", "center", "right"])
                case "midway", "near start", "near end":
                    try bare()
                    state.values["pos"] = key == "midway" ? 0.5 : (key == "near start" ? 0.25 : 0.75)
                case "pos": state.values[key] = try scalar(value)
                case "sloped":
                    try bare()
                    state.values[key] = true
                case "level distance", "sibling distance":
                    guard kind == "scope", assigned else { throw TikZError(key) }
                    state.tree[key] = try length(value)
                case "in", "out", "bend left", "bend right":
                    guard kind == "to" else { throw TikZError(key) }
                    guard assigned || key.hasPrefix("bend ") else { throw TikZError(key) }
                    state.values[key] = assigned ? try scalar(value) : 30
                default:
                    // No unknown cosmetic key is ignored. Only keys handled above can change a picture.
                    if unsupported.count < 12 { unsupported.append(key) }
                }
            }
        }
        if !unsupported.isEmpty { throw TikZError(unsupported.joined(separator: ", ")) }
    }

    /// A later color replaces active ink, including explicit draw/fill colors. It never enables a
    /// disabled paint operation on its own.
    private func setColor(_ color: String, in state: inout TikZScope) {
        state.values["color"] = color
        state.values.removeValue(forKey: "text")
        for channel in ["draw", "fill"] {
            if let current = state.values[channel] as? String, current != "none" {
                state.values[channel] = "currentColor"
            }
        }
    }

    private func distances(_ value: String) throws {
        let parts = value.components(separatedBy: " and ")
        guard parts.count <= 2 else { throw TikZError(value) }
        for part in parts { _ = try length(part) }
    }

    private func tip(_ value: String, to state: inout TikZScope) throws {
        var scanner = TikZScanner(value.tikzUnbraced)
        let name = try scanner.word()
        guard ["Latex", "Stealth", "To", "latex", "stealth", "to"].contains(name) else { throw TikZError(value) }
        state.values[">"] = name
        state.values.removeValue(forKey: "tip length")
        let options = try scanner.options()
        if !options.isEmpty {
            guard ["Latex", "Stealth", "To"].contains(name) else { throw TikZError(value) }
            let values = try TikZScanner.split(options, at: "=")
            guard values.count == 2, values[0] == "length" else { throw TikZError(value) }
            state.values["tip length"] = try length(values[1])
        }
        scanner.space()
        guard scanner.tail.isEmpty else { throw TikZError(value) }
    }
}
