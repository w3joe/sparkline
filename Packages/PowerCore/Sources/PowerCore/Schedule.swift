import Foundation

/// One daily window during which an idle Spark may be shut down. The window may cross midnight.
public struct QuietHours: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Minutes from local midnight, 0...1439.
    public var startMinutes: Int
    public var endMinutes: Int
    /// How long the Spark must stay idle before an automatic shutdown.
    public var idleMinutes: Int
    /// After the window ends, leave the Spark off until someone turns it on.
    public var stayOff: Bool
    /// The Spark was off during the window, so it should be switched on when the window ends.
    public var pendingWake: Bool
    /// Set when someone turns the Spark on during the window. It lasts until the window ends.
    public var holdUntil: Date?

    public static let defaultIdleMinutes = 10

    public init(
        enabled: Bool = false,
        startMinutes: Int = 23 * 60,
        endMinutes: Int = 7 * 60,
        idleMinutes: Int = QuietHours.defaultIdleMinutes,
        stayOff: Bool = true,
        pendingWake: Bool = false,
        holdUntil: Date? = nil
    ) {
        self.enabled = enabled
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.idleMinutes = max(1, idleMinutes)
        self.stayOff = stayOff
        self.pendingWake = pendingWake
        self.holdUntil = holdUntil
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, startMinutes, endMinutes, idleMinutes, stayOff, pendingWake, holdUntil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        startMinutes = try container.decode(Int.self, forKey: .startMinutes)
        endMinutes = try container.decode(Int.self, forKey: .endMinutes)
        idleMinutes = try container.decode(Int.self, forKey: .idleMinutes)
        stayOff = try container.decodeIfPresent(Bool.self, forKey: .stayOff) ?? true
        pendingWake = try container.decodeIfPresent(Bool.self, forKey: .pendingWake) ?? false
        holdUntil = try container.decodeIfPresent(Date.self, forKey: .holdUntil)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(startMinutes, forKey: .startMinutes)
        try container.encode(endMinutes, forKey: .endMinutes)
        try container.encode(idleMinutes, forKey: .idleMinutes)
        try container.encode(stayOff, forKey: .stayOff)
        try container.encode(pendingWake, forKey: .pendingWake)
        try container.encodeIfPresent(holdUntil, forKey: .holdUntil)
    }

    public var idleDuration: TimeInterval { TimeInterval(max(1, idleMinutes) * 60) }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, startMinutes != endMinutes else { return false }
        let now = minutes(from: date, calendar: calendar)
        if startMinutes < endMinutes {
            return now >= startMinutes && now < endMinutes
        }
        return now >= startMinutes || now < endMinutes
    }

    /// When the window that contains `date` ends. Nil outside the window.
    public func windowEnd(containing date: Date, calendar: Calendar = .current) -> Date? {
        guard contains(date, calendar: calendar) else { return nil }
        let startOfDay = calendar.startOfDay(for: date)
        let endToday = startOfDay.addingTimeInterval(TimeInterval(endMinutes * 60))
        if startMinutes < endMinutes { return endToday }
        let now = minutes(from: date, calendar: calendar)
        if now >= startMinutes {
            return calendar.date(byAdding: .day, value: 1, to: endToday)
        }
        return endToday
    }

    private func minutes(from date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

public struct ScheduleSnapshot: Sendable, Equatable {
    public var now: Date
    public var outletOn: Bool
    public var operationInProgress: Bool
    public var workloadKnown: Bool
    public var workloadRunning: Bool
    public var workloadName: String?
    public var idleSince: Date?
    public var retryAfter: Date?
    /// The Spark was off during this window and should come on when it ends.
    public var pendingWake: Bool

    public init(
        now: Date,
        outletOn: Bool,
        operationInProgress: Bool = false,
        workloadKnown: Bool,
        workloadRunning: Bool = false,
        workloadName: String? = nil,
        idleSince: Date? = nil,
        retryAfter: Date? = nil,
        pendingWake: Bool = false
    ) {
        self.now = now
        self.outletOn = outletOn
        self.operationInProgress = operationInProgress
        self.workloadKnown = workloadKnown
        self.workloadRunning = workloadRunning
        self.workloadName = workloadName
        self.idleSince = idleSince
        self.retryAfter = retryAfter
        self.pendingWake = pendingWake
    }
}

public enum ScheduleDecision: Sendable, Equatable {
    case inactive
    case outsideWindow
    case off
    case inProgress
    case held(until: Date)
    case unknownWorkload
    case workload(name: String)
    case retryAfter(Date)
    case waiting(idle: TimeInterval, required: TimeInterval)
    case shutDown
    case turnOn
}

public enum QuietHoursEvaluator {
    public static func decide(
        _ hours: QuietHours,
        _ snapshot: ScheduleSnapshot,
        calendar: Calendar = .current
    ) -> ScheduleDecision {
        guard hours.enabled else { return .inactive }
        guard hours.contains(snapshot.now, calendar: calendar) else {
            guard !hours.stayOff, snapshot.pendingWake, !snapshot.outletOn else { return .outsideWindow }
            if snapshot.operationInProgress { return .inProgress }
            if let retry = snapshot.retryAfter, retry > snapshot.now { return .retryAfter(retry) }
            return .turnOn
        }
        guard snapshot.outletOn else { return .off }
        if snapshot.operationInProgress { return .inProgress }
        if let until = hours.holdUntil, until > snapshot.now { return .held(until: until) }
        if let retry = snapshot.retryAfter, retry > snapshot.now { return .retryAfter(retry) }
        guard snapshot.workloadKnown else { return .unknownWorkload }
        if snapshot.workloadRunning {
            return .workload(name: snapshot.workloadName ?? "A job")
        }
        let required = hours.idleDuration
        let idle = snapshot.idleSince.map { snapshot.now.timeIntervalSince($0) } ?? 0
        if idle < required { return .waiting(idle: max(0, idle), required: required) }
        return .shutDown
    }
}
