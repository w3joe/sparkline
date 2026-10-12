import Foundation
import GRDB
import PowerShared

public struct PowerSample: Sendable, Equatable {
    public var spark: SparkID
    public var date: Date
    public var milliwatts: Int?
    public var outletOn: Bool?
    /// False when the plug couldn't be read; such samples are kept as gaps, never as zero watts.
    public var ok: Bool

    public init(spark: SparkID, date: Date, milliwatts: Int?, outletOn: Bool?, ok: Bool) {
        self.spark = spark
        self.date = date
        self.milliwatts = milliwatts
        self.outletOn = outletOn
        self.ok = ok
    }
}

/// Raw 10-second samples for the last day plus per-minute summaries for 30 days, in SQLite.
public final class HistoryStore: Sendable {
    public static let rawRetention: TimeInterval = 24 * 3_600
    public static let summaryRetention: TimeInterval = 30 * 86_400

    private let db: any DatabaseWriter

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try DatabasePool(path: url.path)
        try Self.migrator.migrate(db)
    }

    private init(writer: any DatabaseWriter) throws {
        db = writer
        try Self.migrator.migrate(db)
    }

    public static func inMemory() throws -> HistoryStore {
        try HistoryStore(writer: DatabaseQueue())
    }

    public static func defaultURL() -> URL {
        URL.applicationSupportDirectory
            .appending(path: "GB10PowerMonitor", directoryHint: .isDirectory)
            .appending(path: "history.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE sample (
                    spark TEXT NOT NULL,
                    ts REAL NOT NULL,
                    mw INTEGER,
                    outletOn INTEGER,
                    ok INTEGER NOT NULL,
                    PRIMARY KEY (spark, ts)
                );
                CREATE INDEX sample_ts ON sample(ts);
                CREATE TABLE minuteSummary (
                    spark TEXT NOT NULL,
                    minute INTEGER NOT NULL,
                    avgW REAL NOT NULL,
                    minW REAL NOT NULL,
                    maxW REAL NOT NULL,
                    n INTEGER NOT NULL,
                    PRIMARY KEY (spark, minute)
                );
                CREATE INDEX minuteSummary_minute ON minuteSummary(minute);
                """)
        }
        return migrator
    }

    /// Stores a sample and folds successful readings into that minute's summary.
    public func record(_ sample: PowerSample) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO sample (spark, ts, mw, outletOn, ok) VALUES (?, ?, ?, ?, ?)",
                arguments: [sample.spark.rawValue, sample.date.timeIntervalSince1970, sample.milliwatts, sample.outletOn, sample.ok]
            )
            guard sample.ok, let mw = sample.milliwatts else { return }
            let watts = Double(mw) / 1000
            let minute = Int((sample.date.timeIntervalSince1970 / 60).rounded(.down)) * 60
            try db.execute(
                sql: """
                    INSERT INTO minuteSummary (spark, minute, avgW, minW, maxW, n) VALUES (?, ?, ?, ?, ?, 1)
                    ON CONFLICT(spark, minute) DO UPDATE SET
                        avgW = (avgW * n + excluded.avgW) / (n + 1),
                        minW = MIN(minW, excluded.minW),
                        maxW = MAX(maxW, excluded.maxW),
                        n = n + 1
                    """,
                arguments: [sample.spark.rawValue, minute, watts, watts, watts]
            )
        }
    }

    @discardableResult
    public func prune(now: Date = Date()) throws -> (samples: Int, minutes: Int) {
        try db.write { db in
            try db.execute(
                sql: "DELETE FROM sample WHERE ts < ?",
                arguments: [now.addingTimeInterval(-Self.rawRetention).timeIntervalSince1970]
            )
            let samples = db.changesCount
            try db.execute(
                sql: "DELETE FROM minuteSummary WHERE minute < ?",
                arguments: [Int(now.addingTimeInterval(-Self.summaryRetention).timeIntervalSince1970)]
            )
            return (samples, db.changesCount)
        }
    }

    public func buckets(for range: ChartRange, now: Date = Date()) throws -> [BucketValue] {
        let since = now.addingTimeInterval(-range.duration).timeIntervalSince1970
        let bucket = Int(range.bucket)
        let sql: String
        switch range {
        case .hour:
            sql = """
                SELECT spark, CAST(ts / \(bucket) AS INTEGER) * \(bucket) AS b,
                       AVG(mw) / 1000.0, MIN(mw) / 1000.0, MAX(mw) / 1000.0
                FROM sample WHERE ok = 1 AND mw IS NOT NULL AND ts >= ?
                GROUP BY spark, b ORDER BY b
                """
        case .day:
            sql = """
                SELECT spark, minute, avgW, minW, maxW
                FROM minuteSummary WHERE minute >= ? ORDER BY minute
                """
        case .week, .month:
            sql = """
                SELECT spark, (minute / \(bucket)) * \(bucket) AS b,
                       SUM(avgW * n) / SUM(n), MIN(minW), MAX(maxW)
                FROM minuteSummary WHERE minute >= ?
                GROUP BY spark, b ORDER BY b
                """
        }
        let start: DatabaseValueConvertible = range == .hour ? since : Int(since)
        return try db.read { db in
            try Row.fetchAll(db, sql: sql, arguments: [start]).compactMap { row in
                guard let spark = SparkID(rawValue: row[0]) else { return nil }
                return BucketValue(
                    spark: spark,
                    start: Date(timeIntervalSince1970: row[1]),
                    avg: row[2], min: row[3], max: row[4]
                )
            }
        }
    }

    public func counts() throws -> (samples: Int, minutes: Int) {
        try db.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sample") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM minuteSummary") ?? 0)
        }
    }

    public func samples(_ spark: SparkID, since: Date) throws -> [PowerSample] {
        try db.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT ts, mw, outletOn, ok FROM sample WHERE spark = ? AND ts >= ? ORDER BY ts",
                arguments: [spark.rawValue, since.timeIntervalSince1970]
            ).map { row in
                PowerSample(
                    spark: spark, date: Date(timeIntervalSince1970: row[0]),
                    milliwatts: row[1], outletOn: row[2], ok: row[3]
                )
            }
        }
    }
}
