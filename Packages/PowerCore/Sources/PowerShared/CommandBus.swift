import Foundation

public struct PowerCommand: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var spark: SparkID
    public var action: PowerAction
    public var createdAt: Date
    public var expiresAt: Date
}

public struct CommandAck: Codable, Sendable, Equatable {
    public var id: UUID
    public var accepted: Bool
    public var message: String
    public var at: Date
}

public enum CommandBusError: Error, LocalizedError, Equatable {
    case appNotRunning
    case unknownOutcome
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .appNotRunning:
            "GB10 Power Monitor isn't running, so nothing was done."
        case .unknownOutcome:
            "GB10 Power Monitor took the command but didn't confirm it. Check the app."
        case .rejected(let message):
            message
        }
    }
}

/// Hands short-lived commands from the widget to the running app through files in the App
/// Group container.
///
/// A command moves `commands/` → `claimed/` with an atomic rename when the app takes it, and
/// the widget withdraws an unanswered command by deleting it from `commands/`. Exactly one of
/// the two can succeed, so a command the widget reported as failed can never run later.
public struct CommandBus: Sendable {
    public let container: SharedContainer
    private let now: @Sendable () -> Date
    private let notify: @Sendable () -> Void

    public init(
        container: SharedContainer,
        now: @escaping @Sendable () -> Date = { Date() },
        notify: @escaping @Sendable () -> Void = CommandBus.postDarwinNotification
    ) {
        self.container = container
        self.now = now
        self.notify = notify
    }

    public static func postDarwinNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(AppGroup.commandNotification as CFString),
            nil, nil, true
        )
    }

    private func fileName(_ id: UUID) -> String { "\(id.uuidString).json" }

    // MARK: Widget side

    @discardableResult
    public func submit(spark: SparkID, action: PowerAction, ttl: TimeInterval = 15) throws -> PowerCommand {
        try container.ensureDirectories()
        let created = now()
        let command = PowerCommand(
            id: UUID(), spark: spark, action: action,
            createdAt: created, expiresAt: created.addingTimeInterval(ttl)
        )
        try container.write(command, to: container.commands.appending(path: fileName(command.id)))
        notify()
        return command
    }

    public func ack(for id: UUID) -> CommandAck? {
        container.read(CommandAck.self, from: container.acks.appending(path: fileName(id)))
    }

    /// Returns true when the command was removed before the app claimed it.
    public func withdraw(_ id: UUID) -> Bool {
        (try? FileManager.default.removeItem(at: container.commands.appending(path: fileName(id)))) != nil
    }

    /// Submits a command and waits for the app to acknowledge it.
    public func send(
        spark: SparkID,
        action: PowerAction,
        ttl: TimeInterval = 15,
        ackTimeout: TimeInterval = 5,
        graceAfterClaim: TimeInterval = 3
    ) async throws -> CommandAck {
        let command = try submit(spark: spark, action: action, ttl: ttl)
        if let ack = await waitForAck(command.id, timeout: ackTimeout) {
            return try finish(ack)
        }
        if withdraw(command.id) {
            throw CommandBusError.appNotRunning
        }
        if let ack = await waitForAck(command.id, timeout: graceAfterClaim) {
            return try finish(ack)
        }
        throw CommandBusError.unknownOutcome
    }

    private func waitForAck(_ id: UUID, timeout: TimeInterval) async -> CommandAck? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let ack = ack(for: id) { return ack }
            if Date() >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finish(_ ack: CommandAck) throws -> CommandAck {
        try? FileManager.default.removeItem(at: container.acks.appending(path: fileName(ack.id)))
        guard ack.accepted else { throw CommandBusError.rejected(ack.message) }
        return ack
    }

    // MARK: App side

    /// Claims every waiting command. Expired or unreadable commands are discarded, never returned.
    public func claimPending() -> [PowerCommand] {
        let fm = FileManager.default
        try? container.ensureDirectories()
        guard let files = try? fm.contentsOfDirectory(at: container.commands, includingPropertiesForKeys: nil) else {
            return []
        }
        var claimed: [PowerCommand] = []
        for file in files where file.pathExtension == "json" {
            let target = container.claimed.appending(path: file.lastPathComponent)
            guard (try? fm.moveItem(at: file, to: target)) != nil else { continue }
            guard let command = container.read(PowerCommand.self, from: target) else {
                try? fm.removeItem(at: target)
                continue
            }
            if now() > command.expiresAt {
                acknowledge(command, accepted: false, message: "The command expired before the app received it.")
                continue
            }
            claimed.append(command)
        }
        return claimed.sorted { $0.createdAt < $1.createdAt }
    }

    public func acknowledge(_ command: PowerCommand, accepted: Bool, message: String) {
        let ack = CommandAck(id: command.id, accepted: accepted, message: message, at: now())
        try? container.write(ack, to: container.acks.appending(path: fileName(command.id)))
        try? FileManager.default.removeItem(at: container.claimed.appending(path: fileName(command.id)))
    }

    /// Deletes leftovers: expired commands, and acks or claims nobody collected.
    public func purge(olderThan age: TimeInterval = 60) {
        let fm = FileManager.default
        let cutoff = now().addingTimeInterval(-age)
        if let files = try? fm.contentsOfDirectory(at: container.commands, includingPropertiesForKeys: nil) {
            for file in files {
                if let command = container.read(PowerCommand.self, from: file), command.expiresAt >= now() { continue }
                try? fm.removeItem(at: file)
            }
        }
        for dir in [container.acks, container.claimed] {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if modified < cutoff { try? fm.removeItem(at: file) }
            }
        }
    }
}

/// Two-tap Shut down in widgets: the first tap arms it for a few seconds.
public struct ShutdownArming: Sendable {
    public let container: SharedContainer
    private let now: @Sendable () -> Date

    public init(container: SharedContainer, now: @escaping @Sendable () -> Date = { Date() }) {
        self.container = container
        self.now = now
    }

    private struct Arm: Codable { var until: Date }

    private func url(_ spark: SparkID) -> URL { container.armed.appending(path: "\(spark.rawValue).json") }

    @discardableResult
    public func arm(_ spark: SparkID, for duration: TimeInterval = 10) throws -> Date {
        try container.ensureDirectories()
        let until = now().addingTimeInterval(duration)
        try container.write(Arm(until: until), to: url(spark))
        return until
    }

    public func armedUntil(_ spark: SparkID) -> Date? {
        guard let arm = container.read(Arm.self, from: url(spark)), arm.until > now() else { return nil }
        return arm.until
    }

    public func disarm(_ spark: SparkID) {
        try? FileManager.default.removeItem(at: url(spark))
    }
}
