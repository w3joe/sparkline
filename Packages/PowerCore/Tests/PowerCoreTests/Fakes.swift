import Foundation
import Synchronization
@testable import PowerCore
import PowerShared

final class VirtualClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    var now: Date { current.withLock { $0 } }

    func advance(_ seconds: TimeInterval) {
        current.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var source: TimeSource {
        TimeSource(
            now: { self.now },
            sleep: { duration in
                try Task.checkCancellation()
                self.advance(duration.timeInterval)
                await Task.yield()
            }
        )
    }
}

actor FakePlug: PlugClient {
    let clock: VirtualClock
    var on: Bool
    var watts: @Sendable (Date) -> Double
    var readFails: @Sendable (Date) -> Bool = { _ in false }
    var readError = PlugError(.unreachable, "simulated outage")
    var setFails = false
    private(set) var setCalls: [Bool] = []
    private(set) var readCount = 0
    private(set) var resetCount = 0

    init(clock: VirtualClock, on: Bool = true, watts: @escaping @Sendable (Date) -> Double = { _ in 60 }) {
        self.clock = clock
        self.on = on
        self.watts = watts
    }

    func setWatts(_ f: @escaping @Sendable (Date) -> Double) { watts = f }
    func setReadFails(_ f: @escaping @Sendable (Date) -> Bool) { readFails = f }
    func setReadError(_ e: PlugError) { readError = e }
    func setSetFails(_ v: Bool) { setFails = v }

    private func reading() -> PlugReading {
        PlugReading(deviceOn: on, powerMilliwatts: on ? Int(watts(clock.now) * 1000) : 0, todayWh: 100, monthWh: 1000)
    }

    func configure(_ credentials: TapoCredentials) async throws {}

    func read(_ spark: SparkID, ip: String) async throws -> PlugReading {
        readCount += 1
        if readFails(clock.now) { throw readError }
        return reading()
    }

    func set(_ spark: SparkID, ip: String, on: Bool) async throws -> PlugReading {
        setCalls.append(on)
        if setFails { throw PlugError(.timeout, "simulated set failure") }
        self.on = on
        return reading()
    }

    func info(_ spark: SparkID, ip: String) async throws -> PlugInfo {
        throw PlugError(.protocolError, "unused")
    }

    func reset() async { resetCount += 1 }
}

final class FakeShell: RemoteShell, Sendable {
    let preflightProblem: String?
    let shutdownResult: RemoteResult
    let delay: Duration?
    private let calls = Mutex(0)

    init(preflightProblem: String? = nil, shutdownResult: RemoteResult = .success(""), delay: Duration? = nil) {
        self.preflightProblem = preflightProblem
        self.shutdownResult = shutdownResult
        self.delay = delay
    }

    var shutdownCalls: Int { calls.withLock { $0 } }

    func preflight(_ config: SparkConfig) async -> String? { preflightProblem }

    func requestShutdown(_ config: SparkConfig) async -> RemoteResult {
        calls.withLock { $0 += 1 }
        if let delay { try? await Task.sleep(for: delay) }
        return shutdownResult
    }

    func checkAccess(_ config: SparkConfig) async -> RemoteResult { .success("gb10-ok") }
}

struct FakeProbe: PortProbe {
    let clock: VirtualClock
    let open: @Sendable (Date) -> Bool

    func isOpen(host: String, port: Int, timeout: Duration) async -> Bool { open(clock.now) }
}

func testSpark(_ id: SparkID = .a, timeout: TimeInterval = 300) -> SparkConfig {
    SparkConfig(
        id: id, plugIP: "10.0.0.10", sshHost: "spark-\(id.rawValue).local", sshUser: "joe",
        offThresholdWatts: 5, shutdownTimeout: timeout
    )
}
