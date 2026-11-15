/// What to do after the reader removes all but one document from a binder.
public enum SingleDocumentBinderPolicy: String, CaseIterable, Sendable {
    case ask
    case leave
    case stay

    public static let defaultValue: Self = .ask

    public static func answer(leaving: Bool, suppressing: Bool) -> Self {
        suppressing ? (leaving ? .leave : .stay) : .ask
    }
}
