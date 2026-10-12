import Foundation

public struct SparkPoint: Codable, Sendable, Equatable {
    public var date: Date
    /// `nil` marks a gap with no readings.
    public var watts: Double?

    public init(date: Date, watts: Double?) {
        self.date = date
        self.watts = watts
    }
}

public struct SparkSnapshot: Codable, Sendable, Identifiable, Equatable {
    public var id: SparkID
    public var name: String
    public var configured: Bool
    public var outlet: OutletState
    public var computer: ComputerStatus
    public var watts: Double?
    /// When the latest successful plug reading was taken.
    public var readingAt: Date?
    public var error: String?
    public var operation: String?
    public var sparkline: [SparkPoint]

    public init(
        id: SparkID, name: String, configured: Bool, outlet: OutletState, computer: ComputerStatus,
        watts: Double?, readingAt: Date?, error: String?, operation: String?, sparkline: [SparkPoint]
    ) {
        self.id = id
        self.name = name
        self.configured = configured
        self.outlet = outlet
        self.computer = computer
        self.watts = watts
        self.readingAt = readingAt
        self.error = error
        self.operation = operation
        self.sparkline = sparkline
    }
}

/// What the app publishes for widgets. Widgets never talk to plugs themselves.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var monitoring: Bool
    public var sparks: [SparkSnapshot]
    public var notice: ActionNotice?

    public init(generatedAt: Date, monitoring: Bool, sparks: [SparkSnapshot], notice: ActionNotice?) {
        self.generatedAt = generatedAt
        self.monitoring = monitoring
        self.sparks = sparks
        self.notice = notice
    }

    public func spark(_ id: SparkID) -> SparkSnapshot? {
        sparks.first { $0.id == id }
    }

    public static func load(from container: SharedContainer) -> WidgetSnapshot? {
        container.read(WidgetSnapshot.self, from: container.snapshot)
    }

    public func write(to container: SharedContainer) throws {
        try container.write(self, to: container.snapshot)
    }
}
