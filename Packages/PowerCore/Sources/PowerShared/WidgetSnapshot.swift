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

/// Glanceable GPU work for widgets. Mirrors `Workload.Activity` without pulling PowerCore into the extension.
public enum WorkActivity: String, Codable, Sendable {
    case idle, loaded, busy

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .loaded: "Loaded"
        case .busy: "Busy"
        }
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
    public var gpuUtilization: Int?
    public var gpuCelsius: Double?
    public var gpuWatts: Double?
    public var activity: WorkActivity
    public var jobName: String?
    public var jobCount: Int
    public var containerCount: Int

    public init(
        id: SparkID, name: String, configured: Bool, outlet: OutletState, computer: ComputerStatus,
        watts: Double?, readingAt: Date?, error: String?, operation: String?, sparkline: [SparkPoint],
        gpuUtilization: Int? = nil, gpuCelsius: Double? = nil, gpuWatts: Double? = nil,
        activity: WorkActivity = .idle, jobName: String? = nil, jobCount: Int = 0, containerCount: Int = 0
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
        self.gpuUtilization = gpuUtilization
        self.gpuCelsius = gpuCelsius
        self.gpuWatts = gpuWatts
        self.activity = activity
        self.jobName = jobName
        self.jobCount = jobCount
        self.containerCount = containerCount
    }

    public var runningSummary: String {
        if let jobName { return jobName }
        if containerCount == 1 { return "1 container" }
        if containerCount > 1 { return "\(containerCount) containers" }
        return activity.label
    }

    enum CodingKeys: String, CodingKey {
        case id, name, configured, outlet, computer, watts, readingAt, error, operation, sparkline
        case gpuUtilization, gpuCelsius, gpuWatts, activity, jobName, jobCount, containerCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(SparkID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        configured = try c.decode(Bool.self, forKey: .configured)
        outlet = try c.decode(OutletState.self, forKey: .outlet)
        computer = try c.decode(ComputerStatus.self, forKey: .computer)
        watts = try c.decodeIfPresent(Double.self, forKey: .watts)
        readingAt = try c.decodeIfPresent(Date.self, forKey: .readingAt)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        operation = try c.decodeIfPresent(String.self, forKey: .operation)
        sparkline = try c.decodeIfPresent([SparkPoint].self, forKey: .sparkline) ?? []
        gpuUtilization = try c.decodeIfPresent(Int.self, forKey: .gpuUtilization)
        gpuCelsius = try c.decodeIfPresent(Double.self, forKey: .gpuCelsius)
        gpuWatts = try c.decodeIfPresent(Double.self, forKey: .gpuWatts)
        activity = try c.decodeIfPresent(WorkActivity.self, forKey: .activity) ?? .idle
        jobName = try c.decodeIfPresent(String.self, forKey: .jobName)
        jobCount = try c.decodeIfPresent(Int.self, forKey: .jobCount) ?? 0
        containerCount = try c.decodeIfPresent(Int.self, forKey: .containerCount) ?? 0
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
