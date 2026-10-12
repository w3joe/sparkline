import Foundation
import PowerShared

public struct ShutdownTiming: Sendable {
    public var pollInterval: Duration
    /// The Spark must look powered down for this long before the outlet is switched off.
    public var confirmDuration: TimeInterval
    public var probeTimeout: Duration

    public init(pollInterval: Duration = .seconds(2), confirmDuration: TimeInterval = 30, probeTimeout: Duration = .seconds(2)) {
        self.pollInterval = pollInterval
        self.confirmDuration = confirmDuration
        self.probeTimeout = probeTimeout
    }
}

public enum ShutdownPhase: Sendable, Equatable {
    case checking
    case requestingShutdown
    case waitingForPowerDown(watts: Double?, remaining: TimeInterval)
    case switchingOff
    case switchingOn
    case cycling

    public var label: String {
        switch self {
        case .checking: "Checking…"
        case .requestingShutdown: "Requesting shutdown over SSH…"
        case .waitingForPowerDown(let watts, let remaining):
            "Waiting for power-down (\(watts.map { String(format: "%.1f W", $0) } ?? "no reading"), \(Int(remaining)) s left)…"
        case .switchingOff: "Switching outlet off…"
        case .switchingOn: "Switching outlet on…"
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
    private let plug: any PlugClient
    private let shell: any RemoteShell
    private let probe: any PortProbe
    private let time: TimeSource
    private let timing: ShutdownTiming
    private var busy: Set<SparkID> = []

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
            let sshOpen = config.hasSSH
                ? await probe.isOpen(host: config.sshHost, port: config.sshPort, timeout: timing.probeTimeout)
                : false
            if sshOpen { return .ok("\(config.name) is already running.") }
            if reading.watts > config.offThresholdWatts {
                return .ok("\(config.name)'s outlet is already on and it's drawing \(Self.format(reading.watts)).")
            }
            return .failed("\(config.name)'s outlet is already on, but the Spark is off. It only starts when power is applied, so use Power cycle outlet in the dashboard.")
        }

        progress(.switchingOn)
        do {
            let after = try await plug.set(config.id, ip: config.plugIP, on: true)
            guard after.deviceOn else { return .failed("\(config.name)'s plug didn't report on after switching.") }
            return .ok("\(config.name)'s outlet is on. The Spark starts when power is applied.")
        } catch {
            return .failed("Couldn't switch \(config.name) on: \(PlugError.wrap(error).message)")
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
            return .ok("\(config.name) shut down and its outlet is off.")
        } catch {
            return .failed("\(config.name) is shut down, but switching its outlet off failed: \(PlugError.wrap(error).message)")
        }
    }

    // MARK: Power cycle

    /// Switches the outlet off and on again, but only when the Spark is already confirmed off:
    /// three consecutive readings at or below the threshold with SSH closed.
    public func powerCycle(_ config: SparkConfig, progress: @Sendable (ShutdownPhase) -> Void = { _ in }) async -> ActionOutcome {
        guard config.hasPlug else { return .failed("\(config.name) has no plug IP set.") }
        guard claim(config.id) else { return .failed("\(config.name) already has an action in progress.") }
        defer { release(config.id) }

        progress(.checking)
        for attempt in 0..<3 {
            if attempt > 0 { try? await time.sleep(timing.pollInterval) }
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

        progress(.cycling)
        do {
            _ = try await plug.set(config.id, ip: config.plugIP, on: false)
            try? await time.sleep(.seconds(5))
            let after = try await plug.set(config.id, ip: config.plugIP, on: true)
            guard after.deviceOn else { return .failed("\(config.name)'s plug didn't report on after the power cycle.") }
            return .ok("\(config.name)'s outlet was power cycled. The Spark starts when power is applied.")
        } catch {
            return .failed("Power cycling \(config.name) failed: \(PlugError.wrap(error).message)")
        }
    }

    static func format(_ watts: Double) -> String {
        String(format: "%.1f W", watts)
    }
}
