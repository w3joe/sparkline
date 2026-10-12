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

    public init(
        id: SparkID,
        name: String? = nil,
        plugIP: String = "",
        sshHost: String = "",
        sshUser: String = "",
        sshPort: Int = 22,
        offThresholdWatts: Double = 5,
        shutdownTimeout: TimeInterval = 300
    ) {
        self.id = id
        self.name = name ?? id.defaultName
        self.plugIP = plugIP
        self.sshHost = sshHost
        self.sshUser = sshUser
        self.sshPort = sshPort
        self.offThresholdWatts = offThresholdWatts
        self.shutdownTimeout = shutdownTimeout
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
