import Foundation
import PowerShared

public struct SparkLiveState: Sendable, Equatable {
    public var id: SparkID
    public var outlet: OutletState = .unknown
    public var computer: ComputerStatus = .unknown
    public var watts: Double?
    public var todayWh: Int?
    public var monthWh: Int?
    public var lastReadingAt: Date?
    public var lastAttemptAt: Date?
    public var error: PlugError?
    public var sshReachable: Bool?
    /// Polling stops after a rejected login, because P110s lock themselves after repeated
    /// failed logins. It resumes when credentials change or the user retries.
    public var authPaused = false
    public var consecutiveFailures = 0

    public init(id: SparkID) {
        self.id = id
    }
}

extension ComputerStatus {
    /// How long after switching on a Spark without SSH counts as starting rather than stuck.
    public static let startupGrace: TimeInterval = 300

    public static func derive(
        outlet: OutletState,
        watts: Double?,
        sshReachable: Bool?,
        threshold: Double,
        operation: ComputerStatus?,
        poweredOnRecently: Bool
    ) -> ComputerStatus {
        if let operation { return operation }
        switch outlet {
        case .unknown: return .unknown
        case .off: return .outletOff
        case .on: break
        }
        if sshReachable == true { return .online }
        guard let watts else { return .unknown }
        if watts <= threshold { return .off }
        return poweredOnRecently ? .starting : .notResponding
    }
}

/// Samples every configured plug on its own schedule: every 10 s while it answers, backing
/// off to 60 s while it doesn't. Readings go to the history store and to `onUpdate`.
public actor Monitor {
    private let plug: any PlugClient
    private let probe: any PortProbe
    private let store: HistoryStore?
    private let time: TimeSource
    private let interval: TimeInterval
    private let maxBackoff: TimeInterval
    private let onUpdate: @Sendable (SparkLiveState) -> Void

    private var configs: [SparkID: SparkConfig] = [:]
    private var states: [SparkID: SparkLiveState] = [:]
    private var tasks: [SparkID: Task<Void, Never>] = [:]
    private var overrides: [SparkID: ComputerStatus] = [:]
    private var poweredOnAt: [SparkID: Date] = [:]

    public init(
        plug: any PlugClient,
        probe: any PortProbe,
        store: HistoryStore?,
        time: TimeSource = .live,
        interval: TimeInterval = 10,
        maxBackoff: TimeInterval = 60,
        onUpdate: @escaping @Sendable (SparkLiveState) -> Void
    ) {
        self.plug = plug
        self.probe = probe
        self.store = store
        self.time = time
        self.interval = interval
        self.maxBackoff = maxBackoff
        self.onUpdate = onUpdate
    }

    public static func delay(afterFailures failures: Int, interval: TimeInterval, maxBackoff: TimeInterval) -> TimeInterval {
        guard failures > 0 else { return interval }
        return min(maxBackoff, interval * pow(2, Double(failures - 1)))
    }

    public func state(_ id: SparkID) -> SparkLiveState {
        states[id] ?? SparkLiveState(id: id)
    }

    /// Starts (or restarts) polling for every Spark with a plug IP.
    public func start(_ sparks: [SparkConfig]) {
        stop()
        configs = Dictionary(uniqueKeysWithValues: sparks.map { ($0.id, $0) })
        for config in sparks where config.hasPlug {
            startLoop(config.id)
        }
    }

    public func stop() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func startLoop(_ id: SparkID) {
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in await self?.run(id) }
    }

    private func run(_ id: SparkID) async {
        while !Task.isCancelled {
            let started = time.now()
            let state = await sampleOnce(id)
            if Task.isCancelled || state.authPaused { return }
            let delay = Self.delay(afterFailures: state.consecutiveFailures, interval: interval, maxBackoff: maxBackoff)
            let remaining = max(0.5, delay - time.now().timeIntervalSince(started))
            do {
                try await time.sleep(.milliseconds(Int(remaining * 1000)))
            } catch {
                return
            }
        }
    }

    /// The network came back: forget stale sessions and poll everything right away.
    public func networkRecovered() async {
        await plug.reset()
        for id in configs.keys {
            states[id]?.consecutiveFailures = 0
        }
        start(Array(configs.values))
    }

    /// Clears an auth pause, e.g. after the user saved new credentials or pressed Retry.
    public func resume() {
        for id in configs.keys {
            states[id]?.authPaused = false
            states[id]?.consecutiveFailures = 0
        }
        start(Array(configs.values))
    }

    public func setOperation(_ id: SparkID, _ status: ComputerStatus?) {
        overrides[id] = status
        guard var state = states[id], let config = configs[id] else { return }
        state.computer = derive(state, config: config)
        states[id] = state
        onUpdate(state)
    }

    public func noteSwitchedOn(_ id: SparkID) {
        poweredOnAt[id] = time.now()
    }

    /// Takes one reading for a Spark, records it and publishes the new state.
    @discardableResult
    public func sampleOnce(_ id: SparkID) async -> SparkLiveState {
        var state = states[id] ?? SparkLiveState(id: id)
        guard let config = configs[id], config.hasPlug else {
            state.error = PlugError(.notConfigured, "No plug IP set")
            states[id] = state
            onUpdate(state)
            return state
        }
        let attempted = time.now()
        state.lastAttemptAt = attempted

        do {
            let reading = try await plug.read(id, ip: config.plugIP)
            state.outlet = reading.deviceOn ? .on : .off
            state.watts = reading.watts
            state.todayWh = reading.todayWh
            state.monthWh = reading.monthWh
            state.lastReadingAt = attempted
            state.error = nil
            state.consecutiveFailures = 0
            try? store?.record(PowerSample(
                spark: id, date: attempted, milliwatts: reading.powerMilliwatts, outletOn: reading.deviceOn, ok: true
            ))
        } catch {
            let plugError = PlugError.wrap(error)
            state.error = plugError
            state.outlet = .unknown
            state.watts = nil
            state.consecutiveFailures += 1
            if plugError.kind == .authFailed { state.authPaused = true }
            try? store?.record(PowerSample(spark: id, date: attempted, milliwatts: nil, outletOn: nil, ok: false))
        }

        if state.outlet == .on, config.hasSSH {
            state.sshReachable = await probe.isOpen(host: config.sshHost, port: config.sshPort, timeout: .seconds(2))
        } else {
            state.sshReachable = state.outlet == .off ? false : nil
        }

        state.computer = derive(state, config: config)
        states[id] = state
        onUpdate(state)
        return state
    }

    private func derive(_ state: SparkLiveState, config: SparkConfig) -> ComputerStatus {
        let recentlyOn = poweredOnAt[state.id].map { time.now().timeIntervalSince($0) < ComputerStatus.startupGrace } ?? false
        return ComputerStatus.derive(
            outlet: state.outlet,
            watts: state.watts,
            sshReachable: state.sshReachable,
            threshold: config.offThresholdWatts,
            operation: overrides[state.id],
            poweredOnRecently: recentlyOn
        )
    }
}
