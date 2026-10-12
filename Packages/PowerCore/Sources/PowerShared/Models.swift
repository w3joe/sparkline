import Foundation

public enum SparkID: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case a, b

    public var id: String { rawValue }

    public var defaultName: String {
        switch self {
        case .a: "Spark A"
        case .b: "Spark B"
        }
    }
}

public enum OutletState: String, Codable, Sendable {
    case on, off, unknown

    public var label: String {
        switch self {
        case .on: "Outlet on"
        case .off: "Outlet off"
        case .unknown: "Outlet unknown"
        }
    }
}

public enum ComputerStatus: String, Codable, Sendable {
    case online
    case starting
    case notResponding
    case off
    case outletOff
    case shuttingDown
    case unknown

    public var label: String {
        switch self {
        case .online: "Running"
        case .starting: "Starting"
        case .notResponding: "Not responding"
        case .off: "Shut down"
        case .outletOff: "Outlet off"
        case .shuttingDown: "Shutting down"
        case .unknown: "Unknown"
        }
    }
}

public enum PowerAction: String, Codable, Sendable {
    case on
    case shutDown

    public var label: String {
        switch self {
        case .on: "On"
        case .shutDown: "Shut down"
        }
    }
}

/// A short status message about an action, shown in the menu and in widgets.
public struct ActionNotice: Codable, Sendable, Equatable {
    public var spark: SparkID?
    public var message: String
    public var success: Bool
    public var at: Date

    public init(spark: SparkID?, message: String, success: Bool, at: Date = Date()) {
        self.spark = spark
        self.message = message
        self.success = success
        self.at = at
    }
}
