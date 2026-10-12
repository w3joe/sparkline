import Foundation
import PowerShared

public struct PlugReading: Codable, Sendable, Equatable {
    public var deviceOn: Bool
    public var powerMilliwatts: Int
    public var todayWh: Int
    public var monthWh: Int

    public init(deviceOn: Bool, powerMilliwatts: Int, todayWh: Int = 0, monthWh: Int = 0) {
        self.deviceOn = deviceOn
        self.powerMilliwatts = powerMilliwatts
        self.todayWh = todayWh
        self.monthWh = monthWh
    }

    public var watts: Double { Double(powerMilliwatts) / 1000 }

    enum CodingKeys: String, CodingKey {
        case deviceOn = "device_on"
        case powerMilliwatts = "power_mw"
        case todayWh = "today_wh"
        case monthWh = "month_wh"
    }
}

public struct PlugInfo: Codable, Sendable, Equatable {
    public var model: String
    public var nickname: String
    public var fwVer: String
    public var mac: String
    public var deviceOn: Bool
    public var rssi: Int

    enum CodingKeys: String, CodingKey {
        case model, nickname, mac, rssi
        case fwVer = "fw_ver"
        case deviceOn = "device_on"
    }
}

public struct PlugError: Error, Codable, Sendable, Equatable, LocalizedError {
    public enum Kind: String, Codable, Sendable {
        case unreachable
        case timeout
        case authFailed = "auth_failed"
        case protocolError = "protocol"
        case notConfigured = "not_configured"
        case badRequest = "bad_request"
        case helperUnavailable = "helper_unavailable"

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .protocolError
        }
    }

    public var kind: Kind
    public var message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public static func wrap(_ error: any Error) -> PlugError {
        error as? PlugError ?? PlugError(.protocolError, error.localizedDescription)
    }

    /// Short, user-facing summary.
    public var summary: String {
        switch kind {
        case .unreachable: "Plug unreachable"
        case .timeout: "Plug timed out"
        case .authFailed: "Tapo login rejected"
        case .protocolError: "Plug error"
        case .notConfigured: "Not set up"
        case .badRequest: "Internal error"
        case .helperUnavailable: "Control helper stopped"
        }
    }

    public var errorDescription: String? { "\(summary): \(message)" }
}

public protocol PlugClient: Sendable {
    func configure(_ credentials: TapoCredentials) async throws
    func read(_ spark: SparkID, ip: String) async throws -> PlugReading
    func set(_ spark: SparkID, ip: String, on: Bool) async throws -> PlugReading
    func info(_ spark: SparkID, ip: String) async throws -> PlugInfo
    /// Drops cached sessions so the next call logs in again.
    func reset() async
}
