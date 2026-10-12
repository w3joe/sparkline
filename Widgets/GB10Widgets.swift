import PowerShared
import SwiftUI
import WidgetKit

@main
struct GB10WidgetBundle: WidgetBundle {
    var body: some Widget {
        SparkPowerWidget()
        SparkPowerSquareWidget()
    }
}

struct SparkPowerWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.current, intent: SelectSparkIntent.self, provider: Provider()) { entry in
            WidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .id(entry.snapshot?.generatedAt)
        }
        .configurationDisplayName("GB10 Power")
        .description("Live power, GPU work, and controls for your DGX Sparks.")
        .supportedFamilies(WidgetKind.families)
    }
}

/// Same widget under the kind used while the square size was being added, so that copy keeps updating too.
struct SparkPowerSquareWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetKind.square, intent: SelectSparkIntent.self, provider: Provider()) { entry in
            WidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .id(entry.snapshot?.generatedAt)
        }
        .configurationDisplayName("GB10 Power")
        .description("Live power, GPU work, and controls for your DGX Sparks.")
        .supportedFamilies(WidgetKind.families)
    }
}

enum WidgetKind {
    static let current = "SparkPowerWidget"
    static let square = "SparkPowerSquare"
    static let families: [WidgetFamily] = [.systemLarge, .systemMedium]
}

struct Entry: TimelineEntry {
    var date: Date
    var choice: SparkChoice
    var snapshot: WidgetSnapshot?
    var armedUntil: [SparkID: Date]
    var notice: ActionNotice?

    static let noticeLifetime: TimeInterval = 180
    /// Older than this, the snapshot probably means the app has stopped.
    static let staleAfter: TimeInterval = 15 * 60

    static func load(_ choice: SparkChoice, at date: Date = Date()) -> Entry {
        let container = SharedContainer.appGroup()
        let snapshot = container.flatMap(WidgetSnapshot.load(from:))
        var armed: [SparkID: Date] = [:]
        if let container {
            let arming = ShutdownArming(container: container)
            for id in SparkID.allCases {
                armed[id] = arming.armedUntil(id)
            }
        }
        let notices = [snapshot?.notice, container?.readWidgetNotice()].compactMap { $0 }
        let latest = notices.max { $0.at < $1.at }
        return Entry(date: date, choice: choice, snapshot: snapshot, armedUntil: armed, notice: latest)
    }

    func isArmed(_ id: SparkID) -> Bool {
        (armedUntil[id] ?? .distantPast) > date
    }

    var visibleNotice: ActionNotice? {
        guard let notice, date.timeIntervalSince(notice.at) < Self.noticeLifetime else { return nil }
        if let spark = notice.spark, !choice.ids.contains(spark) { return nil }
        return notice
    }

    var isStale: Bool {
        guard let snapshot else { return true }
        return date.timeIntervalSince(snapshot.generatedAt) > Self.staleAfter
    }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(
            date: Date(), choice: .both,
            snapshot: WidgetSnapshot(generatedAt: Date(), monitoring: true, sparks: SparkID.allCases.map {
                SparkSnapshot(
                    id: $0, name: $0.defaultName, configured: true, outlet: .on, computer: .online,
                    watts: 48, readingAt: Date(), error: nil, operation: nil,
                    sparkline: (0..<12).map { SparkPoint(date: Date().addingTimeInterval(Double($0 - 11) * 300), watts: 40 + Double($0)) },
                    gpuUtilization: 96, gpuCelsius: 71, gpuWatts: 51,
                    activity: .busy, jobName: "dgpp-serve", jobCount: 1, containerCount: $0 == .a ? 1 : 0
                )
            }, notice: nil),
            armedUntil: [:], notice: nil
        )
    }

    func snapshot(for configuration: SelectSparkIntent, in context: Context) async -> Entry {
        context.isPreview && SharedContainer.appGroup().flatMap(WidgetSnapshot.load(from:)) == nil
            ? placeholder(in: context)
            : Entry.load(configuration.spark)
    }

    func timeline(for configuration: SelectSparkIntent, in context: Context) async -> Timeline<Entry> {
        let now = Date()
        let entry = Entry.load(configuration.spark, at: now)
        var entries = [entry]
        // Follow-up entries flip the view back when a confirmation or notice expires.
        var changes = entry.armedUntil.values.filter { $0 > now }
        if let notice = entry.visibleNotice {
            changes.append(notice.at.addingTimeInterval(Entry.noticeLifetime))
        }
        for change in changes.sorted() {
            var next = entry
            next.date = change.addingTimeInterval(0.5)
            entries.append(next)
        }
        return Timeline(entries: entries, policy: .after(now.addingTimeInterval(15)))
    }
}
