import Foundation
import Testing
@testable import PowerCore

@Suite("Quiet hours")
struct ScheduleTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    func date(day: Int = 1, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func overnight() -> QuietHours {
        QuietHours(enabled: true, startMinutes: 23 * 60, endMinutes: 7 * 60, idleMinutes: 10)
    }

    @Test func windowWrapsPastMidnight() {
        let hours = overnight()
        #expect(hours.contains(date(hour: 23, minute: 30), calendar: calendar))
        #expect(hours.contains(date(day: 2, hour: 2), calendar: calendar))
        #expect(hours.contains(date(hour: 6, minute: 59), calendar: calendar))
        #expect(!hours.contains(date(hour: 7), calendar: calendar))
        #expect(!hours.contains(date(hour: 12), calendar: calendar))
        #expect(hours.windowEnd(containing: date(hour: 23, minute: 30), calendar: calendar) == date(day: 2, hour: 7))
        #expect(hours.windowEnd(containing: date(day: 2, hour: 2), calendar: calendar) == date(day: 2, hour: 7))
    }

    @Test func daytimeWindowDoesNotWrap() {
        let hours = QuietHours(enabled: true, startMinutes: 9 * 60, endMinutes: 17 * 60)
        #expect(hours.contains(date(hour: 9), calendar: calendar))
        #expect(!hours.contains(date(hour: 17), calendar: calendar))
        #expect(hours.windowEnd(containing: date(hour: 12), calendar: calendar) == date(hour: 17))
    }

    @Test func equalEndpointsAreNeverInside() {
        let hours = QuietHours(enabled: true, startMinutes: 8 * 60, endMinutes: 8 * 60)
        #expect(!hours.contains(date(hour: 8), calendar: calendar))
    }

    @Test func workloadHoldAndIdleGateTheShutdown() {
        let hours = overnight()
        let now = date(hour: 23, minute: 30)
        let base = ScheduleSnapshot(now: now, outletOn: true, workloadKnown: true)

        #expect(QuietHoursEvaluator.decide(hours, base, calendar: calendar) == .waiting(idle: 0, required: 600))
        #expect(QuietHoursEvaluator.decide(
            hours,
            ScheduleSnapshot(now: now, outletOn: true, workloadKnown: true, idleSince: now.addingTimeInterval(-9 * 60)),
            calendar: calendar
        ) == .waiting(idle: 9 * 60, required: 600))
        #expect(QuietHoursEvaluator.decide(
            hours,
            ScheduleSnapshot(now: now, outletOn: true, workloadKnown: true, idleSince: now.addingTimeInterval(-10 * 60)),
            calendar: calendar
        ) == .shutDown)

        #expect(QuietHoursEvaluator.decide(
            hours,
            ScheduleSnapshot(now: now, outletOn: true, workloadKnown: true, workloadRunning: true, workloadName: "dgpp-serve"),
            calendar: calendar
        ) == .workload(name: "dgpp-serve"))
        #expect(QuietHoursEvaluator.decide(
            hours,
            ScheduleSnapshot(now: now, outletOn: true, workloadKnown: false),
            calendar: calendar
        ) == .unknownWorkload)

        var held = hours
        held.holdUntil = date(day: 2, hour: 7)
        #expect(QuietHoursEvaluator.decide(held, base, calendar: calendar) == .held(until: date(day: 2, hour: 7)))

        #expect(QuietHoursEvaluator.decide(
            hours,
            ScheduleSnapshot(now: date(hour: 12), outletOn: true, workloadKnown: true, idleSince: date(hour: 11)),
            calendar: calendar
        ) == .outsideWindow)
        #expect(QuietHoursEvaluator.decide(
            hours,
            ScheduleSnapshot(now: now, outletOn: false, workloadKnown: true, idleSince: now.addingTimeInterval(-3600)),
            calendar: calendar
        ) == .off)
        #expect(QuietHoursEvaluator.decide(
            hours,
            ScheduleSnapshot(now: now, outletOn: true, operationInProgress: true, workloadKnown: true, idleSince: now.addingTimeInterval(-3600)),
            calendar: calendar
        ) == .inProgress)
        #expect(QuietHoursEvaluator.decide(QuietHours(), base, calendar: calendar) == .inactive)
    }

    @Test func stayOffLeavesItOffAfterTheWindow() {
        var hours = overnight()
        hours.stayOff = true
        let morning = date(day: 2, hour: 7)
        let off = ScheduleSnapshot(now: morning, outletOn: false, workloadKnown: true, pendingWake: true)
        #expect(QuietHoursEvaluator.decide(hours, off, calendar: calendar) == .outsideWindow)

        hours.stayOff = false
        #expect(QuietHoursEvaluator.decide(hours, off, calendar: calendar) == .turnOn)
        #expect(QuietHoursEvaluator.decide(
            hours,
            ScheduleSnapshot(now: morning, outletOn: true, workloadKnown: true, pendingWake: true),
            calendar: calendar
        ) == .outsideWindow)

        let night = date(hour: 23, minute: 30)
        #expect(QuietHoursEvaluator.decide(
            hours,
            ScheduleSnapshot(now: night, outletOn: true, workloadKnown: true, workloadRunning: true, workloadName: "dgpp-serve"),
            calendar: calendar
        ) == .workload(name: "dgpp-serve"))
    }

    @Test func olderSchedulesStayOffUntilTurnedOn() throws {
        let json = #"{"enabled":true,"startMinutes":60,"endMinutes":120,"idleMinutes":10}"#.data(using: .utf8)!
        let hours = try JSONDecoder().decode(QuietHours.self, from: json)
        #expect(hours.enabled)
        #expect(hours.stayOff)
        #expect(!hours.pendingWake)
    }

    @Test func savedConfigWithoutAScheduleStillLoads() throws {
        let json = """
        {"sparks":[{"id":"a","name":"Spark 1","plugIP":"192.168.50.79","sshHost":"joe-spark-1.local","sshUser":"joe-spark-1","sshPort":22,"offThresholdWatts":5,"shutdownTimeout":300}],"monitoringEnabled":true}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        #expect(config.spark(.a).plugIP == "192.168.50.79")
        #expect(config.spark(.a).schedule.enabled == false)
        let again = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(again == config)
    }
}
