import Foundation
import Testing
@testable import PowerCore
import PowerShared

@Suite("Widget command bus")
struct CommandBusTests {
    let root: URL
    let container: SharedContainer
    let clock = VirtualClock()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "gb10-bus-\(UUID().uuidString)")
        container = SharedContainer(root: root)
        try container.ensureDirectories()
    }

    func bus(realTime: Bool = false) -> CommandBus {
        if realTime { return CommandBus(container: container, notify: {}) }
        let clock = self.clock
        return CommandBus(container: container, now: { clock.now }, notify: {})
    }

    @Test func claimedCommandIsAcknowledgedOnce() throws {
        let bus = bus()
        let command = try bus.submit(spark: .a, action: .shutDown)
        let claimed = bus.claimPending()
        #expect(claimed == [command])
        #expect(bus.claimPending().isEmpty)

        bus.acknowledge(command, accepted: true, message: "ok")
        #expect(bus.ack(for: command.id)?.accepted == true)
    }

    @Test func expiredCommandsAreNeverReturned() throws {
        let bus = bus()
        let command = try bus.submit(spark: .b, action: .on, ttl: 15)
        clock.advance(16)
        #expect(bus.claimPending().isEmpty)
        #expect(bus.ack(for: command.id)?.accepted == false)
    }

    @Test func withdrawnCommandCannotBeClaimed() throws {
        let bus = bus()
        let command = try bus.submit(spark: .a, action: .on)
        #expect(bus.withdraw(command.id))
        #expect(bus.claimPending().isEmpty)
    }

    @Test func claimedCommandCannotBeWithdrawn() throws {
        let bus = bus()
        let command = try bus.submit(spark: .a, action: .on)
        _ = bus.claimPending()
        #expect(!bus.withdraw(command.id))
    }

    @Test func sendFailsFastWhenTheAppIsNotRunning() async throws {
        let bus = bus(realTime: true)
        await #expect(throws: CommandBusError.appNotRunning) {
            try await bus.send(spark: .a, action: .on, ackTimeout: 0.3, graceAfterClaim: 0.3)
        }
        // Nothing is left for the app to find later.
        #expect(bus.claimPending().isEmpty)
    }

    @Test func sendSucceedsWhenTheAppAnswers() async throws {
        let bus = bus(realTime: true)
        let responder = Task {
            for _ in 0..<50 {
                for command in bus.claimPending() {
                    bus.acknowledge(command, accepted: true, message: "Switching on")
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let ack = try await bus.send(spark: .b, action: .on, ackTimeout: 2)
        _ = await responder.value
        #expect(ack.message == "Switching on")
    }

    @Test func rejectionsSurfaceTheAppsMessage() async throws {
        let bus = bus(realTime: true)
        let responder = Task {
            for _ in 0..<50 {
                for command in bus.claimPending() {
                    bus.acknowledge(command, accepted: false, message: "Busy")
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        await #expect(throws: CommandBusError.rejected("Busy")) {
            try await bus.send(spark: .a, action: .shutDown, ackTimeout: 2)
        }
        _ = await responder.value
    }

    @Test func armingExpires() throws {
        let clock = self.clock
        let arming = ShutdownArming(container: container, now: { clock.now })
        try arming.arm(.a, for: 10)
        #expect(arming.armedUntil(.a) != nil)
        #expect(arming.armedUntil(.b) == nil)
        clock.advance(11)
        #expect(arming.armedUntil(.a) == nil)
    }

    @Test func snapshotRoundTrips() throws {
        let snapshot = WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000), monitoring: true,
            sparks: [SparkSnapshot(
                id: .a, name: "Spark A", configured: true, outlet: .on, computer: .online, watts: 42.5,
                readingAt: Date(timeIntervalSince1970: 1_800_000_000), error: nil, operation: nil,
                sparkline: [SparkPoint(date: Date(timeIntervalSince1970: 1_800_000_000), watts: nil)]
            )],
            notice: nil
        )
        try snapshot.write(to: container)
        #expect(WidgetSnapshot.load(from: container) == snapshot)
    }
}
