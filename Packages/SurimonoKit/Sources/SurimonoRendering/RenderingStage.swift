/// Marks the rendering module's current foundation-only implementation.
public enum RenderingStage: Sendable {
    case foundation

    public static let current: Self = .foundation
}
