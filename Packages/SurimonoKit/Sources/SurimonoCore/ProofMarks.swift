/// Which revision of Markdown is put on paper.
public enum ProofMarks: String, Codable, CaseIterable, Sendable {
    case shown, accepted, original
}
