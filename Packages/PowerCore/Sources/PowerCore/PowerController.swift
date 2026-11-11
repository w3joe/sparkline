import Foundation
import PowerShared

public struct ShutdownTiming: Sendable {
    public var pollInterval: Duration
    /// The Spark must look powered down for this long before the outlet is switched off.
    public var confirmDuration: TimeInterval
    /// How long the outlet stays off so the 240 W power brick and EC standby rail fully discharge.
    public var dischargeDuration: TimeInterval
    /// Longer discharge used if the Spark stays in standby draw after the first power-on attempt.
    public var retryDischargeDuration: TimeInterval
    /// How long after switching the outlet on to wait for draw to rise above `offThresholdWatts`.
    public var bootConfirmTimeout: TimeInterval
    public var probeTimeout: Duration

    public init(
        pollInterval: Duration = .seconds(2),
        confirmDuration: TimeInterval = 30,
        dischargeDuration: TimeInterval = 45,
        retryDischargeDuration: TimeInterval = 60,
        bootConfirmTimeout: TimeInterval = 15,
        probeTimeout: Duration = .seconds(2)
    ) {
        self.pollInterval = pollInterval
        self.confirmDuration = confirmDuration
        self.dischargeDuration = dischargeDuration
        self.retryDischargeDuration = retryDischargeDuration
        self.bootConfirmTimeout = bootConfirmTimeout
        self.probeTimeout = probeTimeout
    }
}

public enum ShutdownPhase: Sendable, Equatable {
    case checking
    case requestingShutdown
    case waitingForPowerDown(watts: Double?, remaining: TimeInterval)
    case switchingOff
    case discharging(remaining: TimeInterval)
    case switchingOn
    case waitingForBoot(remaining: TimeInterval)
    case cycling

    public var label: String {
        switch self {
        case .checking: "Checking…"
        case .requestingShutdown: "Requesting shutdown over SSH…"
        case .waitingForPowerDown(let watts, let remaining):
            "Waiting for power-down (\(watts.map { String(format: "%.1f W", $0) } ?? "no reading"), \(Int(remaining)) s left)…"
        case .switchingOff: "Switching outlet off…"
        case .discharging(let remaining):
            "Discharging power brick (\(max(1, Int(remaining.rounded(.up)))) s left)…"
        case .switchingOn: "Switching outlet on…"
        case .waitingForBoot(let remaining):
            "Confirming startup (\(max(1, Int(remaining.rounded(.up)))) s left)…"
        case .cycling: "Power cycling outlet…"
        }
    }
}

public struct ActionOutcome: Sendable, Equatable {
    public var success: Bool
    public var message: String

    public static func ok(_ message: String) -> ActionOutcome { ActionOutcome(success: true, message: message) }
    public static func failed(_ message: String) -> ActionOutcome { ActionOutcome(success: false, message: message) }
}

/// Runs On, Shut down and Power cycle. The outlet is only ever switched off after the
/// Spark has been confirmed powered down; every failure path leaves it on.
public actor PowerController {
    private static let minimumStandbyWatts = 0.3

    private let plug: any PlugClient
    private let shell: any RemoteShell
    private let probe: any PortProbe
    private let time: TimeSource
    private let timing: ShutdownTiming
    private var busy: Set<SparkID> = []
    private var lastSwitchedOffAt: [SparkID: Date] = [:]

    public init(
        plug: any PlugClient,
        shell: any RemoteShell,
        probe: any PortProbe,
        time: TimeSource = .live,
        timing: ShutdownTiming = ShutdownTiming()
    ) {
        self.plug = plug
        self.shell = shell
        self.probe = probe
        self.time = time
        self.timing = timing
    }

    public func isBusy(_ id: SparkID) -> Bool { busy.contains(id) }

    /// Records an outlet transition observed by `Monitor` so a quick Turn On still waits for the
    /// power brick to finish discharging.
    public func noteOutletState(_ id: SparkID, outlet: OutletState) {
        switch outlet {
        case .off:
            if lastSwitchedOffAt[id] == nil {
                lastSwitchedOffAt[id] = time.now()
            }
        case .on:
            if !busy.contains(id) {
                lastSwitchedOffAt[id] = nil
            }
        case .unknown:
            break
        }
    }

    private func claim(_ id: SparkID) -> Bool {
        busy.insert(id).inserted
    }

    private func release(_ id: SparkID) {
        busy.remove(id)
    }

    // MARK: On

    public func switchOn(_ config: SparkConfig, progress: @Sendable (ShutdownPhase) -> Void = { _ in }) async -> ActionOutcome {
        guard config.hasPlug else { return .failed("\(config.name) has no plug IP set.") }
        guard claim(config.id) else { return .failed("\(config.name) already has an action in progress.") }
        defer { release(config.id) }

        progress(.checking)
        let reading: PlugReading
        do {
            reading = try await plug.read(config.id, ip: config.plugIP)
        } catch {
            return .failed("Couldn't reach \(config.name)'s plug: \(PlugError.wrap(error).message)")
        }

        if reading.deviceOn {
            if let outcome = await checkAlreadyRunningOrBooting(config, reading: reading) {
                return outcome
            }
            // The outlet is on while the Spark looks off; confirm two more readings before cycling.
            for _ in 1..<3 {
                do {
                    try await time.sleep(timing.pollInterval)
                } catch {
                    return .failed("Switching \(config.name) on was cancelled.")
                }
                let next: PlugReading
                do {
                    next = try await plug.read(config.id, ip: config.plugIP)
                } catch {
                    return .failed("Couldn't read \(config.name)'s plug: \(PlugError.wrap(error).message). Nothing was changed.")
                }
                if !next.deviceOn {
                    return await turnOnFromOff(config, progress: progress)
                }
                if let outcome = await checkAlreadyRunningOrBooting(config, reading: next) {
                    return outcome
                }
            }
            return await cycleAndConfirmBoot(
                config,
                discharge: timing.dischargeDuration,
                allowRetry: true,
                progress: progress
            )
        }

        return await turnOnFromOff(config, progress: progress)
    }

    private func checkAlreadyRunningOrBooting(_ config: SparkConfig, reading: PlugReading) async -> ActionOutcome? {
        let sshOpen = config.hasSSH
            ? await probe.isOpen(host: config.sshHost, port: config.sshPort, timeout: timing.probeTimeout)
            : false
        if sshOpen { return .ok("\(config.name) is already running.") }
        if reading.watts > config.offThresholdWatts {
            return .ok("\(config.name)'s outlet is already on and it's drawing \(Self.format(reading.watts)).")
        }
        return nil
    }

    private func turnOnFromOff(
        _ config: SparkConfig,
        progress: @Sendable (ShutdownPhase) -> Void
    ) async -> ActionOutcome {
        var dischargedEnough = false
        if let offAt = lastSwitchedOffAt[config.id] {
            let elapsed = time.now().timeIntervalSince(offAt)
            let remaining = timing.dischargeDuration - elapsed
            if remaining > 0 {
                do {
                    try await waitForDischarge(duration: remaining, progress: progress)
                } catch {
                    return .failed("Switching \(config.name) on was cancelled while its outlet was off.")
                }
            }
            dischargedEnough = true
        }

        progress(.switchingOn)
        let after: PlugReading
        do {
            after = try await switchPlugOnWithRetry(config)
        } catch {
            return .failed("Couldn't switch \(config.name) on: \(PlugError.wrap(error).message)")
        }

        switch await confirmBoot(config, initial: after, progress: progress) {
        case .started, .uncertain, .noLoad:
            return .ok("\(config.name)'s outlet is on. The Spark starts when power is applied.")
        case .stuckInStandby(let watts):
            let retryDuration = dischargedEnough ? timing.retryDischargeDuration : max(timing.dischargeDuration, timing.retryDischargeDuration)
            return await cycleAndConfirmBoot(
                config,
                discharge: retryDuration,
                allowRetry: false,
                previousStandbyWatts: watts,
                progress: progress
            )
        }
    }

    // MARK: Shut down

    public func shutDown(_ config: SparkConfig, progress: @Sendable (ShutdownPhase) -> Void = { _ in }) async -> ActionOutcome {
        guard config.hasPlug else { return .failed("\(config.name) has no plug IP set.") }
        guard claim(config.id) else { return .failed("\(config.name) already has an action in progress.") }
        defer { release(config.id) }

        let left = "The outlet was left on."
        progress(.checking)
        let initial: PlugReading
        do {
            initial = try await plug.read(config.id, ip: config.plugIP)
        } catch {
            return .failed("Couldn't read \(config.name)'s plug: \(PlugError.wrap(error).message). Nothing was changed.")
        }
        guard initial.deviceOn else { return .failed("\(config.name)'s outlet is already off.") }
        if let problem = await shell.preflight(config) {
            return .failed("\(problem) \(left)")
        }

        progress(.requestingShutdown)
        if case .failure(let message) = await shell.requestShutdown(config) {
            return .failed("SSH shutdown of \(config.name) failed: \(message) \(left)")
        }

        let deadline = time.now().addingTimeInterval(config.shutdownTimeout)
        var quietSince: Date?
        var lastWatts: Double?
        while true {
            do {
                try await time.sleep(timing.pollInterval)
            } catch {
                return .failed("Shutdown monitoring of \(config.name) was cancelled. \(left)")
            }

            var reading: PlugReading?
            do {
                reading = try await plug.read(config.id, ip: config.plugIP)
            } catch {
                reading = nil
            }
            let sshOpen = await probe.isOpen(host: config.sshHost, port: config.sshPort, timeout: timing.probeTimeout)
            let now = time.now()

            if now >= deadline {
                let detail = lastWatts.map { " Last reading: \(Self.format($0))." } ?? ""
                return .failed("\(config.name) didn't power down within \(Int(config.shutdownTimeout)) s.\(detail) \(left)")
            }

            guard let reading else {
                quietSince = nil
                progress(.waitingForPowerDown(watts: nil, remaining: deadline.timeIntervalSince(now)))
                continue
            }
            guard reading.deviceOn else {
                lastSwitchedOffAt[config.id] = time.now()
                return .failed("\(config.name)'s outlet was switched off by something else during shutdown.")
            }
            lastWatts = reading.watts

            if reading.watts <= config.offThresholdWatts && !sshOpen {
                let since = quietSince ?? now
                quietSince = since
                if now.timeIntervalSince(since) >= timing.confirmDuration { break }
            } else {
                quietSince = nil
            }
            progress(.waitingForPowerDown(watts: reading.watts, remaining: deadline.timeIntervalSince(now)))
        }

        progress(.switchingOff)
        do {
            let after = try await plug.set(config.id, ip: config.plugIP, on: false)
            guard !after.deviceOn else {
                return .failed("\(config.name) is shut down, but its plug still reports on.")
            }
            lastSwitchedOffAt[config.id] = time.now()
            return .ok("\(config.name) shut down and its outlet is off.")
        } catch {
            return .failed("\(config.name) is shut down, but switching its outlet off failed: \(PlugError.wrap(error).message)")
        }
    }

    // MARK: Outlet off (already shut down)

    /// Switches the outlet off without SSH when the Spark is already powered down. Requires
    /// either three consecutive off-level readings (`confirmFullWindow == false`, after user
    /// confirmation) or the full `confirmDuration` window (`confirmFullWindow == true`, used by
    /// automatic quiet-hours cleanup). Any high draw, open SSH port, or read failure leaves the
    /// outlet on.
    public func switchOutletOff(
        _ config: SparkConfig,
        confirmFullWindow: Bool = false,
        progress: @Sendable (ShutdownPhase) -> Void = { _ in }
    ) async -> ActionOutcome {
        guard config.hasPlug else { return .failed("\(config.name) has no plug IP set.") }
        guard claim(config.id) else { return .failed("\(config.name) already has an action in progress.") }
        defer { release(config.id) }

        let left = "The outlet was left on."
        progress(.checking)

        if confirmFullWindow {
            let started = time.now()
            while true {
                let reading: PlugReading
                do {
                    reading = try await plug.read(config.id, ip: config.plugIP)
                } catch {
                    return .failed("Couldn't read \(config.name)'s plug: \(PlugError.wrap(error).message). \(left)")
                }
                if !reading.deviceOn {
                    lastSwitchedOffAt[config.id] = time.now()
                    return .ok("\(config.name)'s outlet is already off.")
                }
                let sshOpen = config.hasSSH
                    ? await probe.isOpen(host: config.sshHost, port: config.sshPort, timeout: timing.probeTimeout)
                    : false
                guard reading.watts <= config.offThresholdWatts, !sshOpen else {
                    return .failed("\(config.name) doesn't look shut down (\(Self.format(reading.watts))\(sshOpen ? ", SSH open" : "")). \(left)")
                }
                let elapsed = time.now().timeIntervalSince(started)
                if elapsed >= timing.confirmDuration { break }
                progress(.waitingForPowerDown(watts: reading.watts, remaining: timing.confirmDuration - elapsed))
                do {
                    try await time.sleep(timing.pollInterval)
                } catch {
                    return .failed("Outlet check for \(config.name) was cancelled. \(left)")
                }
            }
        } else {
            for attempt in 0..<3 {
                if attempt > 0 {
                    do {
                        try await time.sleep(timing.pollInterval)
                    } catch {
                        return .failed("Outlet check for \(config.name) was cancelled. \(left)")
                    }
                }
                let reading: PlugReading
                do {
                    reading = try await plug.read(config.id, ip: config.plugIP)
                } catch {
                    return .failed("Couldn't read \(config.name)'s plug: \(PlugError.wrap(error).message). \(left)")
                }
                if !reading.deviceOn {
                    lastSwitchedOffAt[config.id] = time.now()
                    return .ok("\(config.name)'s outlet is already off.")
                }
                let sshOpen = config.hasSSH
                    ? await probe.isOpen(host: config.sshHost, port: config.sshPort, timeout: timing.probeTimeout)
                    : false
                guard reading.watts <= config.offThresholdWatts, !sshOpen else {
                    return .failed("\(config.name) doesn't look shut down (\(Self.format(reading.watts))\(sshOpen ? ", SSH open" : "")). \(left)")
                }
            }
        }

        progress(.switchingOff)
        do {
            let after = try await plug.set(config.id, ip: config.plugIP, on: false)
            guard !after.deviceOn else {
                return .failed("\(config.name)'s plug still reports on.")
            }
            lastSwitchedOffAt[config.id] = time.now()
            return .ok("\(config.name)'s outlet is off.")
        } catch {
            return .failed("Switching \(config.name)'s outlet off failed: \(PlugError.wrap(error).message)")
        }
    }

    // MARK: Power cycle

    /// Switches the outlet off long enough for the 240 W power brick and EC to discharge, then
    /// switches it back on, but only when the Spark is already confirmed off: three consecutive
    /// readings at or below the threshold with SSH closed.
    public func powerCycle(_ config: SparkConfig, progress: @Sendable (ShutdownPhase) -> Void = { _ in }) async -> ActionOutcome {
        guard config.hasPlug else { return .failed("\(config.name) has no plug IP set.") }
        guard claim(config.id) else { return .failed("\(config.name) already has an action in progress.") }
        defer { release(config.id) }

        progress(.checking)
        for attempt in 0..<3 {
            if attempt > 0 {
                do {
                    try await time.sleep(timing.pollInterval)
                } catch {
                    return .failed("Power cycle of \(config.name) was cancelled. Nothing was changed.")
                }
            }
            let reading: PlugReading
            do {
                reading = try await plug.read(config.id, ip: config.plugIP)
            } catch {
                return .failed("Couldn't read \(config.name)'s plug: \(PlugError.wrap(error).message). Nothing was changed.")
            }
            guard reading.deviceOn else { return .failed("\(config.name)'s outlet is off; use On instead.") }
            let sshOpen = config.hasSSH
                ? await probe.isOpen(host: config.sshHost, port: config.sshPort, timeout: timing.probeTimeout)
                : false
            guard reading.watts <= config.offThresholdWatts, !sshOpen else {
                return .failed("\(config.name) doesn't look shut down (\(Self.format(reading.watts))\(sshOpen ? ", SSH open" : "")). Nothing was changed.")
            }
        }

        return await cycleAndConfirmBoot(
            config,
            discharge: timing.dischargeDuration,
            allowRetry: true,
            progress: progress
        )
    }

    // MARK: Shared boot helpers

    private enum BootCheckResult {
        case started
        case uncertain
        case noLoad
        case stuckInStandby(watts: Double)
    }

    private func cycleAndConfirmBoot(
        _ config: SparkConfig,
        discharge: TimeInterval,
        allowRetry: Bool,
        previousStandbyWatts: Double? = nil,
        progress: @Sendable (ShutdownPhase) -> Void
    ) async -> ActionOutcome {
        _ = previousStandbyWatts
        progress(.switchingOff)
        do {
            let off = try await plug.set(config.id, ip: config.plugIP, on: false)
            guard !off.deviceOn else {
                return .failed("\(config.name)'s plug didn't report off when starting the power cycle.")
            }
            lastSwitchedOffAt[config.id] = time.now()
        } catch {
            return .failed("Power cycling \(config.name) failed: \(PlugError.wrap(error).message)")
        }

        do {
            try await waitForDischarge(duration: discharge, progress: progress)
        } catch {
            return .failed("Power cycling \(config.name) was cancelled while its outlet was off.")
        }

        progress(.switchingOn)
        let after: PlugReading
        do {
            after = try await switchPlugOnWithRetry(config)
        } catch {
            return .failed("Power cycling \(config.name) failed while switching back on: \(PlugError.wrap(error).message)")
        }

        switch await confirmBoot(config, initial: after, progress: progress) {
        case .started, .uncertain, .noLoad:
            return .ok("\(config.name)'s outlet was power cycled. The Spark starts when power is applied.")
        case .stuckInStandby(let watts):
            if allowRetry {
                return await cycleAndConfirmBoot(
                    config,
                    discharge: max(discharge, timing.retryDischargeDuration),
                    allowRetry: false,
                    previousStandbyWatts: watts,
                    progress: progress
                )
            }
            progress(.switchingOff)
            if let off = try? await plug.set(config.id, ip: config.plugIP, on: false), !off.deviceOn {
                lastSwitchedOffAt[config.id] = time.now()
                return .failed("\(config.name) stayed in standby (\(Self.format(watts))) after power cycling and didn't boot. Its outlet was switched off — try Turn On again or press the rear power button.")
            }
            return .failed("\(config.name) stayed in standby (\(Self.format(watts))) after power cycling and didn't boot.")
        }
    }

    private func waitForDischarge(duration: TimeInterval, progress: @Sendable (ShutdownPhase) -> Void) async throws {
        guard duration > 0 else { return }
        let deadline = time.now().addingTimeInterval(duration)
        while true {
            let remaining = deadline.timeIntervalSince(time.now())
            if remaining <= 0 { break }
            progress(.discharging(remaining: remaining))
            let step = min(1.0, remaining)
            try await time.sleep(.milliseconds(max(1, Int((step * 1000).rounded(.up)))))
        }
    }

    private func switchPlugOnWithRetry(_ config: SparkConfig) async throws -> PlugReading {
        var lastError: (any Error)?
        for attempt in 0..<3 {
            if attempt > 0 {
                try await time.sleep(timing.pollInterval)
            }
            do {
                let after = try await plug.set(config.id, ip: config.plugIP, on: true)
                if after.deviceOn {
                    lastSwitchedOffAt[config.id] = nil
                    return after
                }
                lastError = PlugError(.protocolError, "\(config.name)'s plug didn't report on after switching.")
            } catch {
                lastError = error
                let kind = PlugError.wrap(error).kind
                if kind == .authFailed || kind == .notConfigured { throw error }
            }
        }
        throw lastError ?? PlugError(.protocolError, "\(config.name)'s plug didn't report on after switching.")
    }

    private func confirmBoot(
        _ config: SparkConfig,
        initial: PlugReading,
        progress: @Sendable (ShutdownPhase) -> Void
    ) async -> BootCheckResult {
        if initial.watts > config.offThresholdWatts {
            return .started
        }
        if config.hasSSH, await probe.isOpen(host: config.sshHost, port: config.sshPort, timeout: timing.probeTimeout) {
            return .started
        }
        guard timing.bootConfirmTimeout > 0 else {
            return .started
        }

        let deadline = time.now().addingTimeInterval(timing.bootConfirmTimeout)
        var lastWatts = initial.watts
        var sawStandbyLoad = initial.watts >= Self.minimumStandbyWatts

        while true {
            let remaining = deadline.timeIntervalSince(time.now())
            if remaining <= 0 { break }
            progress(.waitingForBoot(remaining: remaining))
            do {
                try await time.sleep(timing.pollInterval)
            } catch {
                return .uncertain
            }

            let reading: PlugReading
            do {
                reading = try await plug.read(config.id, ip: config.plugIP)
            } catch {
                return .uncertain
            }
            guard reading.deviceOn else {
                return .uncertain
            }
            lastWatts = reading.watts
            if reading.watts >= Self.minimumStandbyWatts {
                sawStandbyLoad = true
            }
            if reading.watts > config.offThresholdWatts {
                return .started
            }
            if config.hasSSH, await probe.isOpen(host: config.sshHost, port: config.sshPort, timeout: timing.probeTimeout) {
                return .started
            }
        }

        return sawStandbyLoad ? .stuckInStandby(watts: lastWatts) : .noLoad
    }

    static func format(_ watts: Double) -> String {
        String(format: "%.1f W", watts)
    }
}
