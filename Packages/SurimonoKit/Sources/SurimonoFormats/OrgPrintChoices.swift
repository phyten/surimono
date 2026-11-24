import Foundation

extension OrgReadingDefaults {
    public enum Tags: String, Codable, Sendable, CaseIterable {
        case all = "t"
        case off = "nil"
        case notInContents = "not-in-toc"
    }
    public enum Math: String, Codable, Sendable, CaseIterable {
        case render = "t"
        case off = "nil"
        case verbatim
    }
    public enum Archived: String, Codable, Sendable, CaseIterable {
        case all = "t"
        case off = "nil"
        case headline
    }
    public enum Timestamps: String, Codable, Sendable, CaseIterable {
        case all = "t"
        case off = "nil"
        case active, inactive

        func includes(_ stamp: Substring) -> Bool {
            self == .all || self == (stamp.first == "<" ? .active : .inactive)
        }
    }

    public enum Names: Codable, Hashable, Sendable {
        case off, all
        case including([String])
        case excluding([String])

        init?(token: String, allowsExclusion: Bool) {
            switch token {
            case "t": self = .all
            case "nil": self = .off
            default:
                guard let (exclude, names) = OrgNameList.read(token), !exclude || allowsExclusion else { return nil }
                self = exclude ? .excluding(names) : .including(names)
            }
        }

        func includes(_ name: String) -> Bool {
            switch self {
            case .off: false
            case .all: true
            case .including(let names): names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            case .excluding(let names): !names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            }
        }
    }

    public enum Tasks: Codable, Hashable, Sendable {
        case all, off, todo, done
        case keywords([String])

        init?(token: String) {
            switch token {
            case "t": self = .all
            case "nil": self = .off
            case "todo": self = .todo
            case "done": self = .done
            default:
                guard let (exclude, names) = OrgNameList.read(token), !exclude else { return nil }
                self = .keywords(names)
            }
        }
    }
}

extension OrgOptionToken where Self: RawRepresentable, RawValue == String {
    var token: String { rawValue }
}
extension OrgReadingDefaults.Tags: OrgOptionToken {}
extension OrgReadingDefaults.Math: OrgOptionToken {}
extension OrgReadingDefaults.Archived: OrgOptionToken {}
extension OrgReadingDefaults.Timestamps: OrgOptionToken {}
extension OrgReadingDefaults.Names: OrgOptionToken {
    public var token: String {
        switch self {
        case .all: "t"
        case .off: "nil"
        case .including(let names): OrgNameList.write(names, excluding: false)
        case .excluding(let names): OrgNameList.write(names, excluding: true)
        }
    }
}
extension OrgReadingDefaults.Tasks: OrgOptionToken {
    public var token: String {
        switch self {
        case .all: "t"
        case .off: "nil"
        case .todo: "todo"
        case .done: "done"
        case .keywords(let names): OrgNameList.write(names, excluding: false)
        }
    }
}

/// The small Lisp subset used by drawers, properties and task keywords. Never evaluate an option.
private enum OrgNameList {
    static func read(_ token: String) -> (Bool, [String])? {
        guard token.first == "(", token.last == ")" else { return nil }
        var rest = token.dropFirst().dropLast().drop(while: \.isWhitespace)
        let excluding = rest.hasPrefix("not") && (rest.dropFirst(3).first?.isWhitespace == true)
        if excluding { rest = rest.dropFirst(3).drop(while: \.isWhitespace) }
        var names: [String] = []
        while !rest.isEmpty {
            guard rest.popFirst() == "\"" else { return nil }
            var name = ""
            while let next = rest.first, next != "\"" {
                rest.removeFirst()
                if next == "\\" {
                    guard let escaped = rest.popFirst() else { return nil }
                    name.append(escaped)
                } else {
                    name.append(next)
                }
            }
            guard rest.popFirst() == "\"" else { return nil }
            names.append(name)
            rest = rest.drop(while: \.isWhitespace)
        }
        return (excluding, names)
    }

    static func write(_ names: [String], excluding: Bool) -> String {
        let strings = names.map { name in
            "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return "(" + ((excluding ? ["not"] : []) + strings).joined(separator: " ") + ")"
    }
}
