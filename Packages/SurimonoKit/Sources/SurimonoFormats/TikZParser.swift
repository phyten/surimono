import Foundation

/// Names and numeric expressions are checked here, before a label with an unknown position can reach the page.
final class TikZParser {
    typealias Object = [String: Any]
    var colors: [String: (Double, Double, Double)]
    private var hasLocalColors = false
    var work = 4_000_000
    private var items: [Object] = []
    private var names: Set<String> = []
    var anglePoints: [String: (x: Double, y: Double)] = [:]
    private var operationCount = 0
    private var shapeCount = 0

    private init(colors: [String: (Double, Double, Double)]) { self.colors = colors }

    static func scene(
        _ source: String, styles: String, colors: [String: (Double, Double, Double)],
        label: (String) -> String
    ) throws -> Object {
        guard source.utf8.count <= 2_000_000 else { throw TikZError("picture limit") }
        let parser = TikZParser(colors: colors)
        var scope = TikZScope()
        try parser.apply(styles, to: &scope, kind: "scope")
        var scanner = TikZScanner(source)
        try parser.apply(scanner.options(), to: &scope, kind: "scope")
        try parser.commands(&scanner, scope: scope, depth: 0, label: label)
        guard !parser.items.isEmpty else { throw TikZError("tikzpicture") }
        return ["items": parser.items]
    }

    func append(_ item: Object) throws {
        guard items.count < 10_000 else { throw TikZError("picture limit") }
        if item["kind"] as? String != "endScope", item["kind"] as? String != "scope" { try countShape() }
        items.append(item)
    }

    private func countShape() throws {
        shapeCount += 1
        guard shapeCount <= 5_000 else { throw TikZError("picture limit") }
    }

    private func countOperations(_ count: Int = 1) throws {
        operationCount += count
        guard operationCount <= 80_000 else { throw TikZError("path limit") }
    }

    private func commands(_ input: inout TikZScanner, scope initial: TikZScope, depth: Int, label: (String) -> String)
        throws
    {
        guard depth <= 32 else { throw TikZError("scope limit") }
        var scope = initial
        let savedColors = colors
        let savedLocalFlag = hasLocalColors
        defer {
            colors = savedColors
            hasLocalColors = savedLocalFlag
        }
        input.space()
        while !input.tail.isEmpty {
            guard input.take("\\") else { throw TikZError(String(input.tail.prefix(32))) }
            let command = try input.word()
            switch command {
            case "definecolor", "colorlet":
                let name = try input.group("{", "}").tikzTrimmed
                guard Self.isName(name), !name.contains(":") else { throw TikZError(command) }
                let model = command == "definecolor" ? try input.group("{", "}").tikzTrimmed : nil
                let spec = try input.group("{", "}").tikzTrimmed
                guard let rgb = LaTeXSymbols.rgb(spec, model: model, defined: colors),
                    rgb.0.isFinite, rgb.1.isFinite, rgb.2.isFinite
                else { throw TikZError(command + " " + name) }
                colors[name] = rgb
                hasLocalColors = true
            case "tikzset": try apply(input.group("{", "}"), to: &scope, kind: "scope")
            case "begin":
                let env = try input.group("{", "}")
                let options = try input.options()
                if env == "scope" {
                    var nested = scope
                    try apply(options, to: &nested, kind: "scope")
                    try append(["kind": "scope"])
                    try commands(&input, scope: nested, depth: depth + 1, label: label)
                    try append(["kind": "endScope"])
                } else if ["axis", "semilogxaxis", "semilogyaxis", "loglogaxis"].contains(env) {
                    let end = "\\end{\(env)}"
                    guard let range = input.tail.range(of: end) else { throw TikZError(env) }
                    let source = String(input.tail[..<range.lowerBound])
                    input.tail = input.tail[range.upperBound...]
                    let drawing = try PGFPlots.lower(environment: env, options: options, body: source, colors: colors)
                    guard drawing.source.utf8.count <= work else { throw TikZError("plot limit") }
                    work -= drawing.source.utf8.count
                    var generated = TikZScanner(drawing.source)
                    let start = items.count
                    try commands(&generated, scope: scope, depth: 0, label: label)
                    var roles = drawing.roles.makeIterator()
                    for i in start..<items.count where items[i]["kind"] as? String == "node" {
                        guard let role = roles.next() else { throw TikZError("axis labels") }
                        if !role.isEmpty {
                            items[i]["axisRole"] = role
                            items[i]["axisGroup"] = start
                        }
                    }
                    guard roles.next() == nil else { throw TikZError("axis labels") }
                    if let entry = drawing.legend { try legend(entry, scope: scope, label: label) }
                } else {
                    throw TikZError(env)
                }
            case "end":
                let env = try input.group("{", "}")
                guard depth > 0, env == "scope" else { throw TikZError(env) }
                return
            case "matrix": try matrix(&input, scope: scope, label: label)
            case "pic": try anglePic(&input, scope: scope, label: label)
            case "node", "coordinate":
                let node = try readNode(&input, scope: scope, kind: command, label: label)
                if input.take(";") {
                    try append(node)
                } else if command == "node" {
                    try tree(node, input: &input, scope: scope, depth: 0, distances: scope.tree, label: label)
                    guard input.take(";") else { throw TikZError(String(input.tail.prefix(48))) }
                } else {
                    throw TikZError("coordinate")
                }
            case "path", "draw", "filldraw", "fill", "clip":
                let options = try input.options()
                let paint = try style(options, scope: scope, kind: command)
                try append([
                    "kind": command == "clip" ? "clip" : "path", "style": paint,
                    "ops": try path(&input, style: paint, scope: scope, label: label),
                ])
            default: throw TikZError("\\" + command)
            }
            input.space()
        }
        if depth != 0 { throw TikZError("scope") }
    }

    private func matrix(_ input: inout TikZScanner, scope: TikZScope, label: (String) -> String) throws {
        var name: String?
        var at: Object?
        var options: [String] = []
        while true {
            input.space()
            if input.tail.first == "[" {
                options += try TikZScanner.split(input.options(), at: ",")
            } else if input.tail.first == "(" {
                guard name == nil else { throw TikZError("matrix name") }
                name = try input.group("(", ")").tikzTrimmed
            } else if input.take("at") {
                guard at == nil else { throw TikZError("matrix at") }
                at = try point(&input)
            } else {
                break
            }
        }
        guard let name, Self.isName(name), options.first == "matrix of nodes" else { throw TikZError(#"\matrix"#) }

        var cellOptions = ["anchor=base"]
        var rowSep = "0pt"
        var columnSep = "0pt"
        for option in options where !option.isEmpty && option != "matrix of nodes" {
            let pair = try TikZScanner.split(option, at: "=")
            guard pair.count == 2 else { throw TikZError(option) }
            switch pair[0] {
            case "nodes": cellOptions.append(pair[1].tikzUnbraced)
            case "row sep": rowSep = try length(pair[1])
            case "column sep": columnSep = try length(pair[1])
            default: throw TikZError(pair[0])
            }
        }
        // PGF implicitly applies these handlers by cell index. An explicit style definition must
        // not silently disappear when converting a matrix.
        guard scope.definitions.count <= work else { throw TikZError("matrix limit") }
        work -= scope.definitions.count
        for key in scope.definitions.keys {
            if [
                "every matrix", "every cell", "every odd row", "every even row", "every odd column",
                "every even column",
            ].contains(key)
                || key.hasPrefix("row ") || key.hasPrefix("column ")
            {
                throw TikZError(key)
            }
        }
        guard !rowSep.hasPrefix("-"), !columnSep.hasPrefix("-") else { throw TikZError("matrix separation") }
        let outer = try style("", scope: scope, kind: "node")
        let cells = try style(cellOptions.joined(separator: ","), scope: scope, kind: "node")
        for appearance in [outer, cells] {
            guard appearance["transforms"] == nil, appearance["rotate"] == nil, appearance["sloped"] == nil,
                !Self.directions.contains(where: { appearance[$0] != nil })
            else { throw TikZError("matrix placement") }
        }
        guard outer["anchor"] as? String != "base", outer["text width"] == nil else { throw TikZError("matrix bounds") }
        let rows = try TikZScanner.matrixRows(input.group("{", "}"))
        guard input.take(";") else { throw TikZError(#"\matrix"#) }
        names.insert(name)
        anglePoints.removeValue(forKey: name)
        var labels: [[String]] = []
        for (row, entries) in rows.enumerated() {
            var ids: [String] = []
            for (column, entry) in entries.enumerated() {
                try countShape()
                let cellName = "\(name)-\(row + 1)-\(column + 1)"
                names.insert(cellName)
                anglePoints.removeValue(forKey: cellName)
                ids.append(try labelID(entry, label: label))
            }
            labels.append(ids)
        }
        var item: Object = [
            "kind": "matrix", "name": name, "style": outer, "cellStyle": cells,
            "cells": labels, "rowSep": rowSep, "columnSep": columnSep,
        ]
        item["at"] = at
        try append(item)
    }

    func labelID(_ source: String, label: (String) -> String) throws -> String {
        // Templates are converted by the parent reader after the parse. Its palette cannot see a
        // picture-local color command inside a label; refuse it instead of substituting black.
        if hasLocalColors, source.contains(#"\textcolor"#) || source.contains(#"\color"#) {
            throw TikZError("label color")
        }
        return label(source)
    }

    private func readNode(
        _ input: inout TikZScanner, scope: TikZScope, kind: String,
        label: (String) -> String
    ) throws -> Object {
        var at: Object?
        var name: String?
        var options: [String] = []
        while true {
            input.space()
            if input.tail.first == "[" {
                options.append(try input.options())
            } else if input.take("at") {
                guard at == nil else { throw TikZError("at") }
                at = try point(&input)
            } else if input.tail.first == "(" {
                guard name == nil else { throw TikZError("node name") }
                name = try input.group("(", ")").tikzTrimmed
                guard let name, Self.isName(name) else { throw TikZError("node name") }
            } else {
                break
            }
        }
        let appearance = try style(options.joined(separator: ","), scope: scope, kind: kind)
        var result: Object = ["kind": kind, "style": appearance]
        result["at"] = at
        if kind == "node" {
            let text = try input.group("{", "}")
            result["html"] = try labelID(text, label: label)
        } else if name == nil {
            throw TikZError("coordinate name")
        }
        if let name {
            names.insert(name)
            anglePoints.removeValue(forKey: name)
            if kind == "coordinate", let at, appearance["transforms"] == nil, at["relative"] == nil,
                let x = at["x"] as? String, let y = at["y"] as? String,
                let px = physicalPoints(x, unit: appearance["x"] as? String ?? "1cm"),
                let py = physicalPoints(y, unit: appearance["y"] as? String ?? "1cm")
            {
                anglePoints[name] = (px, py)
            }
            result["name"] = name
        }
        return result
    }

    /// The standard downward tree centers the group of siblings on its parent. Keep the parent as a
    /// symbolic coordinate so moving or rotating the containing scope moves the complete subtree.
    private func tree(
        _ node: Object, input: inout TikZScanner, scope: TikZScope, depth: Int,
        distances inherited: [String: String], label: (String) -> String
    ) throws {
        guard depth < 24 else { throw TikZError("tree limit") }
        // These handlers restyle children or their edges, which the plain layout below would drop.
        for name in ["every child", "every child node", "edge from parent"] where scope.definitions[name] != nil {
            throw TikZError(name)
        }
        var options = try shapeOptions(input.options())
        var distances = inherited
        for key in distances.keys {
            if let value = options.removeValue(forKey: key) { distances[key] = try length(value) }
        }
        guard options.isEmpty else { throw TikZError(options.keys.sorted().joined(separator: ", ")) }
        // PGF applies `level` (with the level number as #1) and then `level <n>` as each child starts,
        // so they override the parent's options for the children and everything below them.
        for (name, argument) in [("level", "\(depth + 1)"), ("level \(depth + 1)", nil)] {
            guard let definition = scope.definitions[name] else { continue }
            guard argument != nil || !definition.contains("#1") else { throw TikZError(name) }
            let keys = try shapeOptions(definition.replacingOccurrences(of: "#1", with: argument ?? ""))
            for (key, value) in keys {
                guard distances[key] != nil else { throw TikZError(name + ": " + key) }
                distances[key] = try length(value)
            }
        }
        let siblingDistance = distances["sibling distance"] ?? "15mm"
        let levelDistance = distances["level distance"] ?? "15mm"
        var children: [String] = []
        while input.take("child") {
            guard children.count < 5_000 else { throw TikZError("tree limit") }
            children.append(try input.group("{", "}"))
        }
        let name = node["name"] as? String ?? "#tree-\(items.count)"
        var parent = node
        parent["name"] = name
        try append(parent)
        for (index, child) in children.enumerated() {
            guard child.utf8.count <= work else { throw TikZError("tree limit") }
            work -= child.utf8.count
            var tokens = TikZScanner(child)
            guard tokens.take("node") else { throw TikZError("child") }
            var next = try readNode(&tokens, scope: scope, kind: "node", label: label)
            guard next["at"] == nil else { throw TikZError("child at") }
            let childName = next["name"] as? String ?? "#tree-\(items.count)"
            let dx = Double(index) - Double(children.count - 1) / 2
            func times(_ distance: String, _ factor: Double) throws -> String {
                let unit = String(distance.reversed().prefix(while: { $0.isLetter }).reversed())
                guard let magnitude = Double(distance.dropLast(unit.count)), abs(magnitude * factor) <= 1e9
                else { throw TikZError("tree distance") }
                return tikzNumber(magnitude * factor) + unit
            }
            next["name"] = childName
            next["at"] =
                [
                    "calc": "add", "a": ["name": name, "anchor": "center"],
                    "b": ["x": try times(siblingDistance, dx), "y": try times(levelDistance, -1)],
                ] as Object
            try tree(next, input: &tokens, scope: scope, depth: depth + 1, distances: distances, label: label)
            tokens.space()
            guard tokens.tail.isEmpty else { throw TikZError(String(tokens.tail.prefix(48))) }
            let ops: [Object] = [["op": "M", "p": ["name": name]], ["op": "L", "p": ["name": childName]]]
            try append(["kind": "path", "ops": ops, "style": try style("", scope: scope, kind: "draw")])
        }
    }

    private func point(_ input: inout TikZScanner) throws -> Object {
        let relative = input.take("++") ? "++" : (input.take("+") ? "+" : nil)
        var p = try coordinatesInside(input.group("(", ")"))
        if relative != nil, p["x"] == nil { throw TikZError("relative coordinate") }
        p["relative"] = relative
        return p
    }

    func coordinate(_ source: String) throws -> Object {
        var input = TikZScanner(source)
        let p = try point(&input)
        input.space()
        guard input.tail.isEmpty else { throw TikZError(source) }
        return p
    }

    private static func isName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 120
            && value.allSatisfy { $0.isLetter || $0.isNumber || "_-:".contains($0) }
    }

    func named(_ raw: String) throws -> Object {
        let components = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let name = components.first, names.contains(name) else { throw TikZError(raw) }
        if components.count == 1 { return ["name": name] }
        let anchor = components[1]
        return ["name": name, "anchor": try normalizedAnchor(anchor)]
    }

    private func coordinatesInside(_ source: String) throws -> Object {
        let value = source.tikzTrimmed
        guard value.utf8.count <= 1024 else { throw TikZError("coordinate limit") }
        if value.first == "$", value.last == "$" {
            var reader = TikZScanner(String(value.dropFirst().dropLast()))
            // Each calc operand is a simple node or coordinate, never another recursive calc expression.
            func operand(_ reader: inout TikZScanner) throws -> Object {
                let atom = try reader.group("(", ")")
                guard !atom.contains("$") else { throw TikZError("calc") }
                return try coordinatesInside(atom)
            }
            let a = try operand(&reader)
            var computed: Object
            if reader.take("!") {
                guard let i = reader.tail.firstIndex(of: "!") else { throw TikZError("calc") }
                let t = try scalar(String(reader.tail[..<i]))
                reader.tail = reader.tail[reader.tail.index(after: i)...]
                computed = ["a": a, "t": t, "calc": "lerp", "b": try operand(&reader)]
            } else if reader.take("+") {
                let delta = try operand(&reader)
                guard delta["x"] != nil else { throw TikZError("calc addition") }
                computed = ["a": a, "calc": "add", "b": delta]
            } else {
                throw TikZError("calc")
            }
            reader.space()
            guard reader.tail.isEmpty else { throw TikZError("calc") }
            return computed
        }
        for op in ["|-", "-|"] {
            let parts = value.components(separatedBy: op)
            if parts.count == 2 {
                return ["a": try named(parts[0].tikzTrimmed), "b": try named(parts[1].tikzTrimmed), "calc": op]
            }
        }
        let components = try TikZScanner.split(value, at: ",")
        if components.count == 2 { return ["x": try length(components[0]), "y": try length(components[1])] }
        if names.contains(value) { return ["name": value] }
        let polar = try TikZScanner.split(value, at: ":")
        if polar.count == 2 {
            let angle = try scalar(polar[0]) * Double.pi / 180
            let radius = try length(polar[1])
            let unit = String(radius.reversed().prefix(while: { $0.isLetter }).reversed())
            guard let number = Double(radius.dropLast(unit.count)) else { throw TikZError(value) }
            return ["x": tikzNumber(number * cos(angle)) + unit, "y": tikzNumber(number * sin(angle)) + unit]
        }
        return try named(value)
    }

    private func path(
        _ input: inout TikZScanner, style appearance: Object, scope: TikZScope,
        label: (String) -> String
    ) throws -> [Object] {
        var ops: [Object] = []
        var nodeScope = scope
        // The line's own paint and arrow tips do not add a frame or fill to a node on the line.
        for key in ["color", "font", "x", "y", "transforms", "text", "node distance"] {
            if let value = appearance[key] { nodeScope.values[key] = value }
        }
        while !input.take(";") {
            try countOperations()
            input.space()
            if input.take("node") {
                guard !ops.isEmpty else { throw TikZError("node") }
                try countShape()
                var node = try readNode(&input, scope: nodeScope, kind: "node", label: label)
                node.removeValue(forKey: "kind")
                node["op"] = "node"
                ops.append(node)
            } else if input.take("plot") {
                let plot = try plot(&input)
                guard ops.isEmpty else { throw TikZError("plot after path") }
                ops.append(contentsOf: plot)
            } else if ["(", "+"].contains(input.tail.first.map(String.init) ?? "") {
                ops.append(["op": "M", "p": try point(&input)])
            } else {
                guard !ops.isEmpty else { throw TikZError(String(input.tail.prefix(24))) }
                let token: String
                if let primitive = ["--", "|-", "-|", ".."].first(where: { input.tail.hasPrefix($0) }) {
                    _ = input.take(primitive)
                    token = primitive
                } else {
                    token = try input.word()
                }
                if token == "cycle" {
                    ops.append(["op": "Z"])
                    continue
                }
                if token == "--", input.take("cycle") {
                    ops.append(["op": "Z"])
                    continue
                }
                var op: Object = [:]
                switch token {
                case "circle", "ellipse":
                    let radii = try ellipse(&input, circle: token == "circle")
                    ops.append(["op": "ellipse", "rx": radii.0, "ry": radii.1])
                    continue
                case "arc":
                    ops.append(try arc(&input))
                    continue
                case "--", "|-", "-|", "rectangle": op["op"] = token == "--" ? "L" : token
                case "to":
                    op["op"] = "to"
                    op["style"] = try style(input.options(), scope: TikZScope(), kind: "to")
                case "..":
                    guard input.take("controls") else { throw TikZError("controls") }
                    op["c1"] = try point(&input)
                    guard input.take("and") else { throw TikZError("controls") }
                    op["c2"] = try point(&input)
                    guard input.take("..") else { throw TikZError("controls") }
                    op["op"] = "C"
                case "grid":
                    let options = try TikZScanner.split(input.options(), at: "=")
                    if options == [""] {
                        op["step"] = appearance["step"] ?? "1cm"
                    } else if options.count == 2, options[0] == "step" {
                        op["step"] = try length(options[1])
                    } else {
                        throw TikZError("grid")
                    }
                    op["op"] = "grid"
                default: throw TikZError(token)
                }
                var pending: [Object] = []
                while input.take("node") {
                    try countShape()
                    var node = try readNode(&input, scope: nodeScope, kind: "node", label: label)
                    node.removeValue(forKey: "kind")
                    node["op"] = "node"
                    node["segment"] = true
                    pending.append(node)
                }
                op["p"] = try point(&input)
                ops.append(op)
                ops.append(contentsOf: pending)
            }
        }
        guard !ops.isEmpty else { throw TikZError("path") }
        if appearance["rounded corners"] != nil,
            ops.contains(where: { op in
                let kind = op["op"] as? String
                return kind == "C" || kind == "arc" || kind == "to"
            })
        {
            throw TikZError("rounded corners with curve")
        }
        return ops
    }

    private func ellipse(_ input: inout TikZScanner, circle: Bool) throws -> (String, String) {
        input.space()
        if input.tail.first == "[" {
            let options = try shapeOptions(input.options())
            if let r = options["radius"], options.count == 1 { return (try length(r), try length(r)) }
            if !circle, options.count == 2, let x = options["x radius"], let y = options["y radius"] {
                return (try length(x), try length(y))
            }
            throw TikZError(options.keys.sorted().joined(separator: ", "))
        }
        let value = try input.group("(", ")")
        if circle {
            let radius = try length(value)
            return (radius, radius)
        }
        let parts = value.components(separatedBy: " and ")
        guard parts.count == 2 else { throw TikZError("ellipse") }
        return (try length(parts[0]), try length(parts[1]))
    }

    private func shapeOptions(_ options: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for item in try TikZScanner.split(options, at: ",") where !item.isEmpty {
            let parts = try TikZScanner.split(item, at: "=")
            guard parts.count == 2 else { throw TikZError(item) }
            result[parts[0]] = parts[1].tikzUnbraced
        }
        return result
    }

    private func arc(_ input: inout TikZScanner) throws -> Object {
        input.space()
        if input.tail.first == "(" {
            let parts = try TikZScanner.split(input.group("(", ")"), at: ":")
            guard parts.count == 3 else { throw TikZError("arc") }
            let radius = try length(parts[2])
            return [
                "op": "arc", "start": try scalar(parts[0]), "end": try scalar(parts[1]), "rx": radius, "ry": radius,
            ]
        }
        var params = try shapeOptions(input.options())
        guard let start = params.removeValue(forKey: "start angle"), let end = params.removeValue(forKey: "end angle")
        else { throw TikZError("arc angles") }
        let radius = params.removeValue(forKey: "radius")
        let rx = params.removeValue(forKey: "x radius") ?? radius
        let ry = params.removeValue(forKey: "y radius") ?? radius
        guard params.isEmpty, let rx, let ry else { throw TikZError("arc radius") }
        return [
            "op": "arc", "start": try scalar(start), "end": try scalar(end), "rx": try length(rx), "ry": try length(ry),
        ]
    }

    private func plot(_ input: inout TikZScanner) throws -> [Object] {
        var options = try shapeOptions(input.options())
        var points: [Object] = []
        if input.take("coordinates") {
            guard options.isEmpty else { throw TikZError("plot options") }
            var values = TikZScanner(try input.group("{", "}"))
            values.space()
            while !values.tail.isEmpty {
                guard points.count < 2_000 else { throw TikZError("plot samples") }
                points.append(try point(&values))
                values.space()
            }
        } else {
            let range = try TikZScanner.split(options.removeValue(forKey: "domain") ?? "-5:5", at: ":")
            let samples = Int(options.removeValue(forKey: "samples") ?? "25")
            guard let samples, (2...2_000).contains(samples), range.count == 2 else {
                throw TikZError("plot samples/domain")
            }
            guard options.isEmpty else { throw TikZError(options.keys.sorted().joined(separator: ", ")) }
            let a = try scalar(range[0])
            let b = try scalar(range[1])
            let pair = try TikZScanner.split(input.group("(", ")"), at: ",")
            guard pair.count == 2 else { throw TikZError("plot") }
            let cost = (pair[0].utf8.count + pair[1].utf8.count + 1) * samples
            guard cost <= work else { throw TikZError("plot limit") }
            work -= cost
            for i in 0..<samples {
                let t = a + (b - a) * Double(i) / Double(samples - 1)
                points.append(["x": try length(pair[0], variable: t), "y": try length(pair[1], variable: t)])
            }
        }
        guard !points.isEmpty else { throw TikZError("empty plot") }
        try countOperations(points.count)
        return points.enumerated().map { ["op": $0.offset == 0 ? "M" : "L", "p": $0.element] }
    }
}
