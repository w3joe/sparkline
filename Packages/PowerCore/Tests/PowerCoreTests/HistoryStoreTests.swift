import Foundation
import Testing
@testable import PowerCore
import PowerShared

@Suite("History store")
struct HistoryStoreTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func minuteSummariesAverageSuccessfulReadings() throws {
        let store = try HistoryStore.inMemory()
        let minute = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        for (offset, mw) in [(0.0, 40_000), (10, 50_000), (20, 60_000)] {
            try store.record(PowerSample(spark: .a, date: minute + offset, milliwatts: mw, outletOn: true, ok: true))
        }
        try store.record(PowerSample(spark: .a, date: minute + 30, milliwatts: nil, outletOn: nil, ok: false))

        let buckets = try store.buckets(for: .day, now: minute + 40)
        #expect(buckets.count == 1)
        let bucket = try #require(buckets.first)
        #expect(abs(bucket.avg - 50) < 0.001)
        #expect(bucket.min == 40)
        #expect(bucket.max == 60)
        #expect(try store.counts() == (samples: 4, minutes: 1))
    }

    @Test func failedSamplesProduceGapsNotZeros() throws {
        let store = try HistoryStore.inMemory()
        let start = now.addingTimeInterval(-600)
        for i in 0..<60 {
            let date = start.addingTimeInterval(Double(i) * 10)
            let outage = (20..<40).contains(i)
            try store.record(PowerSample(
                spark: .a, date: date, milliwatts: outage ? nil : 50_000, outletOn: outage ? nil : true, ok: !outage
            ))
        }
        let buckets = try store.buckets(for: .hour, now: now)
        #expect(buckets.count == 40)
        #expect(buckets.allSatisfy { $0.avg == 50 })

        let points = ChartSeriesBuilder.points(from: buckets, bucket: ChartRange.hour.bucket, sparks: [.a])
        #expect(Set(points.map(\.segment)) == [0, 1])
    }

    @Test func retentionKeepsOneDayRawAndThirtyDaysOfMinutes() throws {
        let store = try HistoryStore.inMemory()
        // One reading every 5 minutes for 31 days.
        let step: TimeInterval = 300
        let count = Int(31 * 86_400 / step)
        for i in 0..<count {
            let date = now.addingTimeInterval(-Double(i) * step)
            try store.record(PowerSample(spark: .a, date: date, milliwatts: 45_000, outletOn: true, ok: true))
        }
        #expect(try store.counts() == (samples: count, minutes: count))

        try store.prune(now: now)
        let (samples, minutes) = try store.counts()
        #expect(samples == Int(86_400 / step) + 1)
        #expect(minutes == Int(30 * 86_400 / step) + 1)

        let month = try store.buckets(for: .month, now: now)
        #expect(month.first.map { $0.start >= now.addingTimeInterval(-30 * 86_400 - 3_600) } == true)
        #expect(month.count >= 30 * 24)
    }

    @Test func weekBucketsWeightByReadingCount() throws {
        let store = try HistoryStore.inMemory()
        let base = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 900).rounded(.down) * 900)
        // Minute 1: six readings at 60 W. Minute 2: one reading at 0 W.
        for i in 0..<6 {
            try store.record(PowerSample(spark: .b, date: base + Double(i) * 10, milliwatts: 60_000, outletOn: true, ok: true))
        }
        try store.record(PowerSample(spark: .b, date: base + 60, milliwatts: 0, outletOn: true, ok: true))

        let buckets = try store.buckets(for: .week, now: base + 120)
        #expect(buckets.count == 1)
        #expect(abs((buckets.first?.avg ?? 0) - 360.0 / 7) < 0.001)
    }

    @Test func persistsAcrossReopen() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "gb10-\(UUID().uuidString)/history.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let store = try HistoryStore(url: url)
            try store.record(PowerSample(spark: .a, date: now, milliwatts: 1_000, outletOn: true, ok: true))
        }
        let reopened = try HistoryStore(url: url)
        #expect(try reopened.counts().samples == 1)
    }
}

@Suite("Chart series")
struct ChartSeriesTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func bucket(_ spark: SparkID, _ i: Int, _ w: Double, width: TimeInterval = 60) -> BucketValue {
        BucketValue(spark: spark, start: t0 + Double(i) * width, avg: w, min: w - 1, max: w + 1)
    }

    @Test func totalOnlyWhereEverySparkHasData() {
        let buckets = [bucket(.a, 0, 10), bucket(.b, 0, 20), bucket(.a, 1, 11), bucket(.b, 2, 22), bucket(.a, 2, 12)]
        let points = ChartSeriesBuilder.points(from: buckets, bucket: 60, sparks: [.a, .b])
        let totals = points.filter { $0.series == .total }
        #expect(totals.map(\.watts) == [30, 34])
        #expect(totals.map(\.min) == [28, 32])
    }

    @Test func gapsStartNewSegments() {
        let buckets = [bucket(.a, 0, 1), bucket(.a, 1, 1), bucket(.a, 2, 1), bucket(.a, 6, 1), bucket(.a, 7, 1)]
        let points = ChartSeriesBuilder.points(from: buckets, bucket: 60, sparks: [.a], includeTotal: false)
        #expect(points.map(\.segment) == [0, 0, 0, 1, 1])
    }

    @Test func oneMissingBucketIsBridged() {
        let buckets = [bucket(.a, 0, 1), bucket(.a, 2, 1)]
        let points = ChartSeriesBuilder.points(from: buckets, bucket: 60, sparks: [.a], includeTotal: false)
        #expect(points.map(\.segment) == [0, 0])
    }

    @Test func sparklineMarksEmptySlotsAsGaps() {
        let buckets = [bucket(.a, 0, 10, width: 10), bucket(.a, 1, 20, width: 10), bucket(.a, 5, 30, width: 10)]
        let line = ChartSeriesBuilder.sparkline(from: buckets, spark: .a, end: t0 + 60, span: 60, slots: 3)
        #expect(line.map(\.watts) == [15, nil, 30])
    }

    @Test func energyIntegratesBuckets() {
        let points = ChartSeriesBuilder.points(
            from: (0..<60).map { bucket(.a, $0, 120) }, bucket: 60, sparks: [.a], includeTotal: false
        )
        #expect(abs(ChartSeriesBuilder.energyWh(points, bucket: 60) - 120) < 0.001)
    }
}
