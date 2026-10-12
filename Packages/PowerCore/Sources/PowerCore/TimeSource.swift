import Foundation

/// Wall-clock time and sleeping, injectable so tests can run timeouts instantly.
public struct TimeSource: Sendable {
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    public static let live = TimeSource(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
