import Foundation
import Synchronization
import Testing
@testable import PowerCore
import PowerShared

@Suite("Monitor and status")
struct MonitorTests {
    let clock = VirtualClock()

    @Test func backoffDoublesUpToTheCap() {
        let delays = (0...5).map { Monitor.delay(afterFailures: $0, interval: 10, maxBackoff: 60) }
        #expect(delays == [10, 10, 20, 40, 60, 60])
    }

    @Test func statusDerivation() {
        func derive(_ outlet: OutletState, _ watts: Double?, _ ssh: Bool?, op: ComputerStatus? = nil, recent: Bool = false) -> ComputerStatus {
            ComputerStatus.derive(outlet: outlet, watts: watts, sshReachable: ssh, threshold: 5, operation: op, poweredOnRecently: recent)
        }
        #expect(derive(.on, 60, true) == .online)
        #expect(derive(.on, 2, false) == .off)
        #expect(derive(.on, 40, false) == .notResponding)
        #expect(derive(.on, 40, false, recent: true) == .starting)
        #expect(derive(.off, 0, false) == .outletOff)
        #expect(derive(.unknown, nil, nil) == .unknown)
        #expect(derive(.on, 60, true, op: .shuttingDown) == .shuttingDown)
    }

    @Test func successfulSampleIsRecorded() async throws {
        let store = try HistoryStore.inMemory()
        let plug = FakePlug(clock: clock, watts: { _ in 55 })
        let monitor = Monitor(plug: plug, probe: FakeProbe(clock: clock, open: { _ in true }), store: store, time: clock.source, onUpdate: { _ in })
        await monitor.start([testSpark()])
        await monitor.stop()

        let state = await monitor.sampleOnce(.a)
        #expect(state.outlet == .on)
        #expect(state.watts == 55)
        #expect(state.computer == .online)
        #expect(state.error == nil)
        #expect(try store.counts().samples >= 1)
    }

    @Test func unreachablePlugRecordsAGapAndBacksOff() async throws {
        let store = try HistoryStore.inMemory()
        let plug = FakePlug(clock: clock)
        await plug.setReadFails { _ in true }
        let monitor = Monitor(plug: plug, probe: FakeProbe(clock: clock, open: { _ in false }), store: store, time: clock.source, onUpdate: { _ in })
        await monitor.start([testSpark()])
        await monitor.stop()

        var state = await monitor.sampleOnce(.a)
        clock.advance(10)
        state = await monitor.sampleOnce(.a)
        #expect(state.error?.kind == .unreachable)
        #expect(state.outlet == .unknown)
        #expect(state.watts == nil)
        #expect(state.consecutiveFailures >= 2)
        #expect(!state.authPaused)
        let samples = try store.samples(.a, since: .distantPast)
        #expect(samples.contains { !$0.ok && $0.milliwatts == nil })
    }

    @Test func rejectedLoginPausesPolling() async throws {
        let plug = FakePlug(clock: clock)
        await plug.setReadFails { _ in true }
        await plug.setReadError(PlugError(.authFailed, "bad password"))
        let monitor = Monitor(plug: plug, probe: FakeProbe(clock: clock, open: { _ in false }), store: nil, time: clock.source, onUpdate: { _ in })
        await monitor.start([testSpark()])
        // The polling loop stops by itself after one rejected login.
        try await Task.sleep(for: .milliseconds(200))
        let reads = await plug.readCount
        try await Task.sleep(for: .milliseconds(200))
        #expect(await plug.readCount == reads)
        #expect(await monitor.state(.a).authPaused)
        await monitor.stop()
    }

    @Test func plugsAreIndependent() async throws {
        let plug = FakePlug(clock: clock, watts: { _ in 30 })
        let monitor = Monitor(plug: plug, probe: FakeProbe(clock: clock, open: { _ in true }), store: nil, time: clock.source, onUpdate: { _ in })
        var broken = testSpark(.b)
        broken.plugIP = ""
        await monitor.start([testSpark(.a), broken])
        await monitor.stop()
        let a = await monitor.sampleOnce(.a)
        let b = await monitor.sampleOnce(.b)
        #expect(a.watts == 30)
        #expect(b.error?.kind == .notConfigured)
    }

    @Test func networkRecoveryResetsSessions() async {
        let plug = FakePlug(clock: clock)
        let monitor = Monitor(plug: plug, probe: FakeProbe(clock: clock, open: { _ in true }), store: nil, time: clock.source, onUpdate: { _ in })
        await monitor.start([testSpark()])
        await monitor.networkRecovered()
        await monitor.stop()
        #expect(await plug.resetCount == 1)
    }
}
