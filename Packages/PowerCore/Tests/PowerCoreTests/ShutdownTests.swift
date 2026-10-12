import Foundation
import Testing
@testable import PowerCore
import PowerShared

@Suite("Shutdown safety")
struct ShutdownTests {
    let clock = VirtualClock()

    func controller(plug: FakePlug, shell: FakeShell, open: @escaping @Sendable (Date) -> Bool) -> PowerController {
        PowerController(plug: plug, shell: shell, probe: FakeProbe(clock: clock, open: open), time: clock.source)
    }

    /// Watts drop to 2 W and SSH closes `after` seconds from now.
    func poweringDown(after seconds: TimeInterval) -> (watts: @Sendable (Date) -> Double, open: @Sendable (Date) -> Bool) {
        let t0 = clock.now
        return ({ $0.timeIntervalSince(t0) < seconds ? 60 : 2 }, { $0.timeIntervalSince(t0) < seconds - 5 })
    }

    @Test func switchesOffOnlyAfterConfirmedPowerDown() async {
        let profile = poweringDown(after: 20)
        let plug = FakePlug(clock: clock, watts: profile.watts)
        let shell = FakeShell()
        let start = clock.now
        let outcome = await controller(plug: plug, shell: shell, open: profile.open).shutDown(testSpark())

        #expect(outcome.success, "\(outcome.message)")
        #expect(shell.shutdownCalls == 1)
        #expect(await plug.setCalls == [false])
        // Quiet from 20 s, confirmed after another 30 s.
        #expect(clock.now.timeIntervalSince(start) >= 50)
    }

    @Test func sshFailureNeverCutsPower() async {
        let plug = FakePlug(clock: clock, watts: { _ in 1 })
        let shell = FakeShell(shutdownResult: .failure("Permission denied"))
        let outcome = await controller(plug: plug, shell: shell, open: { _ in false }).shutDown(testSpark())

        #expect(!outcome.success)
        #expect(outcome.message.contains("left on"))
        #expect(await plug.setCalls.isEmpty)
    }

    @Test func preflightFailureSkipsSSHAndKeepsPower() async {
        let plug = FakePlug(clock: clock)
        let shell = FakeShell(preflightProblem: "Host key not verified.")
        let outcome = await controller(plug: plug, shell: shell, open: { _ in true }).shutDown(testSpark())

        #expect(!outcome.success)
        #expect(shell.shutdownCalls == 0)
        #expect(await plug.setCalls.isEmpty)
    }

    @Test func timeoutNeverCutsPower() async {
        let plug = FakePlug(clock: clock, watts: { _ in 60 })
        let shell = FakeShell()
        let start = clock.now
        let outcome = await controller(plug: plug, shell: shell, open: { _ in true }).shutDown(testSpark(timeout: 120))

        #expect(!outcome.success)
        #expect(outcome.message.contains("didn't power down"))
        #expect(await plug.setCalls.isEmpty)
        #expect(clock.now.timeIntervalSince(start) >= 120)
    }

    @Test func lowWattsWithSSHStillOpenIsNotEnough() async {
        let plug = FakePlug(clock: clock, watts: { _ in 1 })
        let outcome = await controller(plug: plug, shell: FakeShell(), open: { _ in true }).shutDown(testSpark(timeout: 90))

        #expect(!outcome.success)
        #expect(await plug.setCalls.isEmpty)
    }

    @Test func sshClosedButWattsHighIsNotEnough() async {
        let plug = FakePlug(clock: clock, watts: { _ in 30 })
        let outcome = await controller(plug: plug, shell: FakeShell(), open: { _ in false }).shutDown(testSpark(timeout: 90))

        #expect(!outcome.success)
        #expect(await plug.setCalls.isEmpty)
    }

    @Test func plugReadErrorsNeverConfirm() async {
        let plug = FakePlug(clock: clock, watts: { _ in 1 })
        let t0 = clock.now
        // The first read (pre-check) succeeds; every read after the SSH request fails.
        await plug.setReadFails { $0 > t0 }
        let outcome = await controller(plug: plug, shell: FakeShell(), open: { _ in false }).shutDown(testSpark(timeout: 90))

        #expect(!outcome.success)
        #expect(await plug.setCalls.isEmpty)
    }

    @Test func aSpikeRestartsTheConfirmationWindow() async {
        let t0 = clock.now
        // Quiet from 10 s, a spike at 30–34 s, quiet again afterwards.
        let plug = FakePlug(clock: clock) { date in
            let t = date.timeIntervalSince(t0)
            if t < 10 { return 60 }
            if t >= 30 && t < 34 { return 40 }
            return 2
        }
        let outcome = await controller(plug: plug, shell: FakeShell(), open: { _ in false }).shutDown(testSpark())

        #expect(outcome.success)
        #expect(clock.now.timeIntervalSince(t0) >= 64)
        #expect(await plug.setCalls == [false])
    }

    @Test func confirmationAfterTheDeadlineDoesNotCount() async {
        let profile = poweringDown(after: 45)
        let plug = FakePlug(clock: clock, watts: profile.watts)
        let outcome = await controller(plug: plug, shell: FakeShell(), open: profile.open).shutDown(testSpark(timeout: 60))

        #expect(!outcome.success)
        #expect(await plug.setCalls.isEmpty)
    }

    @Test func alreadyOffOutletIsReportedWithoutSSH() async {
        let plug = FakePlug(clock: clock, on: false)
        let shell = FakeShell()
        let outcome = await controller(plug: plug, shell: shell, open: { _ in false }).shutDown(testSpark())

        #expect(!outcome.success)
        #expect(shell.shutdownCalls == 0)
        #expect(await plug.setCalls.isEmpty)
    }

    @Test func unreachablePlugBeforeShutdownChangesNothing() async {
        let plug = FakePlug(clock: clock)
        await plug.setReadFails { _ in true }
        let shell = FakeShell()
        let outcome = await controller(plug: plug, shell: shell, open: { _ in true }).shutDown(testSpark())

        #expect(!outcome.success)
        #expect(shell.shutdownCalls == 0)
        #expect(await plug.setCalls.isEmpty)
    }

    @Test func failedSwitchOffIsReported() async {
        let profile = poweringDown(after: 10)
        let plug = FakePlug(clock: clock, watts: profile.watts)
        await plug.setSetFails(true)
        let outcome = await controller(plug: plug, shell: FakeShell(), open: profile.open).shutDown(testSpark())

        #expect(!outcome.success)
        #expect(outcome.message.contains("switching its outlet off failed"))
    }

    @Test func secondActionWhileBusyIsRejected() async {
        let plug = FakePlug(clock: clock, watts: { _ in 60 })
        let shell = FakeShell(shutdownResult: .failure("nope"), delay: .milliseconds(300))
        let controller = controller(plug: plug, shell: shell, open: { _ in true })
        let first = Task { await controller.shutDown(testSpark()) }
        try? await Task.sleep(for: .milliseconds(100))
        let second = await controller.switchOn(testSpark())
        _ = await first.value

        #expect(!second.success)
        #expect(second.message.contains("in progress"))
        #expect(await plug.setCalls.isEmpty)
    }
}

@Suite("On and power cycle")
struct SwitchOnTests {
    let clock = VirtualClock()

    func controller(_ plug: FakePlug, open: Bool) -> PowerController {
        PowerController(plug: plug, shell: FakeShell(), probe: FakeProbe(clock: clock, open: { _ in open }), time: clock.source)
    }

    @Test func switchesOnWhenOff() async {
        let plug = FakePlug(clock: clock, on: false)
        let outcome = await controller(plug, open: false).switchOn(testSpark())
        #expect(outcome.success)
        #expect(await plug.setCalls == [true])
    }

    @Test func runningSparkIsLeftAlone() async {
        let plug = FakePlug(clock: clock, on: true)
        let outcome = await controller(plug, open: true).switchOn(testSpark())
        #expect(outcome.success)
        #expect(await plug.setCalls.isEmpty)
    }

    @Test func onOutletWithOffSparkSuggestsPowerCycle() async {
        let plug = FakePlug(clock: clock, on: true, watts: { _ in 1.5 })
        let outcome = await controller(plug, open: false).switchOn(testSpark())
        #expect(!outcome.success)
        #expect(outcome.message.contains("Power cycle"))
        #expect(await plug.setCalls.isEmpty)
    }

    @Test func powerCycleRefusesARunningSpark() async {
        let plug = FakePlug(clock: clock, on: true, watts: { _ in 45 })
        let outcome = await controller(plug, open: false).powerCycle(testSpark())
        #expect(!outcome.success)
        #expect(await plug.setCalls.isEmpty)
    }

    @Test func powerCycleRefusesWhenSSHIsOpen() async {
        let plug = FakePlug(clock: clock, on: true, watts: { _ in 1 })
        let outcome = await controller(plug, open: true).powerCycle(testSpark())
        #expect(!outcome.success)
        #expect(await plug.setCalls.isEmpty)
    }

    @Test func powerCycleSwitchesOffThenOnForAnOffSpark() async {
        let plug = FakePlug(clock: clock, on: true, watts: { _ in 1 })
        let outcome = await controller(plug, open: false).powerCycle(testSpark())
        #expect(outcome.success)
        #expect(await plug.setCalls == [false, true])
    }
}
