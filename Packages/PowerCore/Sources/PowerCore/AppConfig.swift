import Foundation
import PowerShared

public struct SparkConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: SparkID
    public var name: String
    public var plugIP: String
    public var sshHost: String
    public var sshUser: String
    public var sshPort: Int
    /// At or below this draw (with SSH closed) the Spark counts as powered down.
    public var offThresholdWatts: Double
    /// How long to wait for a requested shutdown to finish before giving up with the outlet on.
    public var shutdownTimeout: TimeInterval
    public var schedule: QuietHours

    public init(
        id: SparkID,
        name: String? = nil,
        plugIP: String = "",
        sshHost: String = "",
        sshUser: String = "",
        sshPort: Int = 22,
        offThresholdWatts: Double = 5,
        shutdownTimeout: TimeInterval = 300,
        schedule: QuietHours = QuietHours()
    ) {
        self.id = id
        self.name = name ?? id.defaultName
        self.plugIP = plugIP
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.offThresholdWatts = offThresholdWatts
        self.shutdownTimeout = shutdownTimeout
        self.schedule = schedule
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, plugIP, sshHost, sshUser, sshPort, offThresholdWatts, shutdownTimeout, schedule
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SparkID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        plugIP = try container.decode(String.self, forKey: .plugIP)
        sshHost = try container.decode(String.self, forKey: .sshHost)
        sshUser = try container.decode(String.self, forKey: .sshUser)
        sshPort = try container.decode(Int.self, forKey: .sshPort)
        offThresholdWatts = try container.decode(Double.self, forKey: .offThresholdWatts)
        shutdownTimeout = try container.decode(TimeInterval.self, forKey: .shutdownTimeout)
        schedule = try container.decodeIfPresent(QuietHours.self, forKey: .schedule) ?? QuietHours()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(plugIP, forKey: .plugIP)
        try container.encode(sshHost, forKey: .sshHost)
        try container.encode(sshUser, forKey: .sshUser)
        try container.encode(sshPort, forKey: .sshPort)
        try container.encode(offThresholdWatts, forKey: .offThresholdWatts)
        try container.encode(shutdownTimeout, forKey: .shutdownTimeout)
        try container.encode(schedule, forKey: .schedule)
    }

    public var hasPlug: Bool { !plugIP.trimmingCharacters(in: .whitespaces).isEmpty }
    public var hasSSH: Bool {
        !sshHost.trimmingCharacters(in: .whitespaces).isEmpty
            && !sshUser.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

public struct AppConfig: Codable, Sendable, Equatable {
    public var sparks: [SparkConfig]
    public var monitoringEnabled: Bool

    public init(sparks: [SparkConfig] = SparkID.allCases.map { SparkConfig(id: $0) }, monitoringEnabled: Bool = true) {
        self.sparks = sparks
        self.monitoringEnabled = monitoringEnabled
    }

    public func spark(_ id: SparkID) -> SparkConfig {
        sparks.first { $0.id == id } ?? SparkConfig(id: id)
    }

    public mutating func update(_ config: SparkConfig) {
        if let index = sparks.firstIndex(where: { $0.id == config.id }) {
            sparks[index] = config
        } else {
            sparks.append(config)
        }
    }
}

public struct ConfigStore: Sendable {
    private let key = "appConfig.v1"
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults { suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    public func load() -> AppConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }

    public func save(_ config: AppConfig) {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: key)
        }
    }
}
