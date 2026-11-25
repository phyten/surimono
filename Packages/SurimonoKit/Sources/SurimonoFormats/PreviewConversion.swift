import Foundation

/// Only Finder installs a deadline. Its synchronous provider owns all work until the reply is ready.
package enum PreviewConversion {
    @TaskLocal package static var deadline: ContinuousClock.Instant?

    package static var isActive: Bool { deadline != nil }

    package static var expired: Bool {
        guard let deadline else { return false }
        return ContinuousClock.now >= deadline || StackSpace.isCancelled
    }

    package static func check() throws {
        if expired { throw CancellationError() }
    }
}
