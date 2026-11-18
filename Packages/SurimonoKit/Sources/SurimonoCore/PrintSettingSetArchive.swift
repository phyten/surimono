import Foundation

public enum PrintSettingSetArchive {
    public enum FileError: Error { case unsupportedVersion, invalid }

    private struct Envelope: Codable {
        let surimono: Int
        let sets: [PrintSettingSet]
    }

    public static func encode(_ sets: [PrintSettingSet]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Envelope(surimono: 1, sets: sets))
    }

    public static func decode(_ data: Data) throws -> [PrintSettingSet] {
        struct Version: Decodable { let surimono: Int }
        let decoder = JSONDecoder()
        if let header = try? decoder.decode(Version.self, from: data) {
            guard header.surimono == 1 else { throw FileError.unsupportedVersion }
            guard let file = try? decoder.decode(Envelope.self, from: data) else { throw FileError.invalid }
            return file.sets
        }
        guard let array = try? decoder.decode([PrintSettingSet].self, from: data) else { throw FileError.invalid }
        return array
    }

    public static func merge(_ incoming: [PrintSettingSet], into existing: [PrintSettingSet]) -> (
        additions: [PrintSettingSet], alreadyHere: [String]
    ) {
        var names = Dictionary(existing.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var additions: [PrintSettingSet] = []
        var skipped: [String] = []
        for original in incoming {
            var copy = original
            var suffix = 2
            while let other = names[copy.name] {
                // The UUID belongs to the local list. Only the stored choices decide equality here.
                copy.id = other.id
                if copy == other { break }
                copy.name = "\(original.name) \(suffix)"
                suffix += 1
            }
            if names[copy.name] != nil {
                skipped.append(copy.name)
            } else {
                copy.id = UUID()
                names[copy.name] = copy
                additions.append(copy)
            }
        }
        return (additions, skipped)
    }
}
