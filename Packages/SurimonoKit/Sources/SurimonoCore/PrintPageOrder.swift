/// Which sheet the printer prints first. The default prints the last sheet first, so sheets that come out face up
/// stack in reading order.
public enum PrintPageOrder: String, CaseIterable, Sendable {
    case lastSheetFirst
    case firstSheetFirst
}
