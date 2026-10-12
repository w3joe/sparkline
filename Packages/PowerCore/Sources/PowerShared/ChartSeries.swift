import Foundation

public enum ChartRange: String, CaseIterable, Sendable, Identifiable {
    case hour, day, week, month

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hour: "1H"
        case .day: "24H"
        case .week: "7D"
        case .month: "30D"
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .hour: 3_600
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    /// Width of one chart bucket in seconds.
    public var bucket: TimeInterval {
        switch self {
        case .hour: 10
        case .day: 60
        case .week: 900
        case .month: 3_600
        }
    }
}

/// One aggregated bucket of readings for one Spark.
public struct BucketValue: Sendable, Equatable {
    public var spark: SparkID
    public var start: Date
    public var avg: Double
    public var min: Double
    public var max: Double

    public init(spark: SparkID, start: Date, avg: Double, min: Double, max: Double) {
        self.spark = spark
        self.start = start
        self.avg = avg
        self.min = min
        self.max = max
    }
}

public enum ChartSeriesKey: Hashable, Sendable {
    case spark(SparkID)
    case total

    public var id: String {
        switch self {
        case .spark(let id): id.rawValue
        case .total: "total"
        }
    }
}

public struct ChartPoint: Sendable, Identifiable, Equatable {
    public var series: ChartSeriesKey
    /// Points in different segments must not be joined; a new segment starts after a gap.
    public var segment: Int
    public var date: Date
    public var watts: Double
    public var min: Double
    public var max: Double

    public var id: String { "\(series.id)-\(date.timeIntervalSince1970)" }
    public var lineID: String { "\(series.id)#\(segment)" }
}

public enum ChartSeriesBuilder {
    /// Consecutive buckets further apart than this many bucket widths are drawn as a gap.
    public static let gapFactor = 2.5

    public static func points(
        from buckets: [BucketValue],
        bucket: TimeInterval,
        sparks: [SparkID],
        includeTotal: Bool = true
    ) -> [ChartPoint] {
        var result: [ChartPoint] = []
        for spark in sparks {
            let rows = buckets.filter { $0.spark == spark }.sorted { $0.start < $1.start }
            result += segmented(rows.map { ($0.start, $0.avg, $0.min, $0.max) }, series: .spark(spark), bucket: bucket)
        }
        if includeTotal, sparks.count > 1 {
            var byStart: [Date: [SparkID: BucketValue]] = [:]
            for value in buckets where sparks.contains(value.spark) {
                byStart[value.start, default: [:]][value.spark] = value
            }
            // A total is only meaningful when every Spark has a reading for that bucket.
            let totals = byStart
                .filter { $0.value.count == sparks.count }
                .map { start, values in
                    (start,
                     values.values.reduce(0) { $0 + $1.avg },
                     values.values.reduce(0) { $0 + $1.min },
                     values.values.reduce(0) { $0 + $1.max })
                }
                .sorted { $0.0 < $1.0 }
            result += segmented(totals, series: .total, bucket: bucket)
        }
        return result
    }

    private static func segmented(
        _ rows: [(Date, Double, Double, Double)],
        series: ChartSeriesKey,
        bucket: TimeInterval
    ) -> [ChartPoint] {
        var segment = 0
        var previous: Date?
        return rows.map { start, avg, min, max in
            if let previous, start.timeIntervalSince(previous) > bucket * gapFactor {
                segment += 1
            }
            previous = start
            return ChartPoint(series: series, segment: segment, date: start, watts: avg, min: min, max: max)
        }
    }

    /// Resamples buckets onto a fixed grid for a compact sparkline; empty slots become gaps.
    public static func sparkline(
        from buckets: [BucketValue],
        spark: SparkID,
        end: Date,
        span: TimeInterval,
        slots: Int
    ) -> [SparkPoint] {
        guard slots > 0 else { return [] }
        let start = end.addingTimeInterval(-span)
        let width = span / Double(slots)
        var sums = [Double](repeating: 0, count: slots)
        var counts = [Int](repeating: 0, count: slots)
        for value in buckets where value.spark == spark && value.start >= start && value.start < end {
            let index = min(slots - 1, Int(value.start.timeIntervalSince(start) / width))
            sums[index] += value.avg
            counts[index] += 1
        }
        return (0..<slots).map { i in
            SparkPoint(
                date: start.addingTimeInterval(Double(i) * width),
                watts: counts[i] > 0 ? sums[i] / Double(counts[i]) : nil
            )
        }
    }

    /// Energy in watt-hours, treating each bucket's average as constant over the bucket.
    public static func energyWh(_ points: [ChartPoint], bucket: TimeInterval) -> Double {
        points.reduce(0) { $0 + $1.watts * bucket / 3_600 }
    }
}
