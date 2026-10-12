import AppIntents
import Charts
import PowerShared
import SwiftUI
import WidgetKit

struct WidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        if let snapshot = entry.snapshot {
            content(snapshot)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("GB10 Power", systemImage: "bolt.fill")
                    .font(.headline)
                    .widgetAccentable()
                Spacer()
                Text("Open GB10 Power Monitor to start monitoring.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetSnapshot) -> some View {
        let sparks = entry.choice.ids.compactMap(snapshot.spark)
        switch (family, sparks.count) {
        case (.systemSmall, 1):
            SingleSparkSmall(spark: sparks[0], entry: entry, snapshot: snapshot)
        case (.systemSmall, _):
            BothSparksSmall(sparks: sparks, entry: entry, snapshot: snapshot)
        case (_, 1):
            SingleSparkMedium(spark: sparks[0], entry: entry, snapshot: snapshot)
        default:
            HStack(spacing: 14) {
                ForEach(Array(sparks.enumerated()), id: \.element.id) { index, spark in
                    if index > 0 { Divider() }
                    SparkColumn(spark: spark, entry: entry, snapshot: snapshot)
                }
            }
        }
    }
}

// MARK: Layouts

private struct SingleSparkSmall: View {
    let spark: SparkSnapshot
    let entry: Entry
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SparkHeader(spark: spark)
            Spacer(minLength: 4)
            Watts(watts: spark.watts, size: 34)
            StatusLine(spark: spark, entry: entry, snapshot: snapshot)
            Spacer(minLength: 8)
            PrimaryAction(spark: spark, entry: entry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SingleSparkMedium: View {
    let spark: SparkSnapshot
    let entry: Entry
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                SparkHeader(spark: spark)
                Spacer(minLength: 4)
                Watts(watts: spark.watts, size: 34)
                StatusLine(spark: spark, entry: entry, snapshot: snapshot)
                Spacer(minLength: 8)
                PrimaryAction(spark: spark, entry: entry)
            }
            .frame(width: 136, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text("Last hour")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Sparkline(points: spark.sparkline, showsAxis: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SparkColumn: View {
    let spark: SparkSnapshot
    let entry: Entry
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SparkHeader(spark: spark)
            Spacer(minLength: 2)
            Watts(watts: spark.watts, size: 26)
            StatusLine(spark: spark, entry: entry, snapshot: snapshot)
            Sparkline(points: spark.sparkline, showsAxis: false)
                .frame(height: 22)
                .padding(.vertical, 4)
            PrimaryAction(spark: spark, entry: entry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct BothSparksSmall: View {
    let sparks: [SparkSnapshot]
    let entry: Entry
    let snapshot: WidgetSnapshot

    private var total: Double? {
        let values = sparks.map(\.watts)
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("GB10 Power", systemImage: "bolt.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Watts(watts: total, size: 30)
            Spacer(minLength: 6)
            VStack(spacing: 6) {
                ForEach(sparks) { spark in
                    HStack(spacing: 6) {
                        StatusSymbol(status: spark.computer)
                        Text(spark.name).font(.caption.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(WidgetFormat.watts(spark.watts))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 6)
            FooterLine(entry: entry, snapshot: snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Pieces

private struct SparkHeader: View {
    let spark: SparkSnapshot

    var body: some View {
        HStack(spacing: 5) {
            StatusSymbol(status: spark.computer)
            Text(spark.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
    }
}

private struct StatusSymbol: View {
    let status: ComputerStatus

    var body: some View {
        Image(systemName: status.widgetSymbol)
            .font(.caption)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(status.widgetColor)
            .widgetAccentable()
    }
}

private struct Watts: View {
    let watts: Double?
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(WidgetFormat.number(watts))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .widgetAccentable()
            Text("W")
                .font(.system(size: size * 0.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }
}

/// Status, or a recent action result, or a warning that the app looks stopped.
private struct StatusLine: View {
    let spark: SparkSnapshot
    let entry: Entry
    let snapshot: WidgetSnapshot

    var body: some View {
        Group {
            if let operation = spark.operation {
                Text(operation)
            } else if let notice = entry.visibleNotice, notice.spark == spark.id || notice.spark == nil {
                Text(notice.message).foregroundStyle(notice.success ? .secondary : Color.orange)
            } else if entry.isStale {
                Text("App not running?").foregroundStyle(.orange)
            } else if let error = spark.error {
                Text(error).foregroundStyle(.orange)
            } else {
                Text("\(spark.computer.label) · \(WidgetFormat.time(spark.readingAt ?? snapshot.generatedAt))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct FooterLine: View {
    let entry: Entry
    let snapshot: WidgetSnapshot

    var body: some View {
        Group {
            if let notice = entry.visibleNotice {
                Text(notice.message).foregroundStyle(notice.success ? .secondary : Color.orange)
            } else if entry.isStale {
                Text("App not running?").foregroundStyle(.orange)
            } else if !snapshot.monitoring {
                Text("Monitoring paused").foregroundStyle(.orange)
            } else {
                Text("Updated \(WidgetFormat.time(updatedAt))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var updatedAt: Date {
        entry.choice.ids.compactMap { snapshot.spark($0)?.readingAt }.max() ?? snapshot.generatedAt
    }
}

/// One clear action per Spark: Turn On when the outlet is off, Shut Down when it's on.
/// Shut Down needs a second tap on Confirm within 10 seconds.
private struct PrimaryAction: View {
    let spark: SparkSnapshot
    let entry: Entry

    var body: some View {
        Group {
            if !spark.configured || spark.operation != nil || spark.outlet == .unknown {
                Color.clear.frame(height: 22)
            } else if entry.isArmed(spark.id) {
                HStack(spacing: 4) {
                    Button(intent: ConfirmShutdownIntent(spark.id)) {
                        Text("Confirm").frame(maxWidth: .infinity)
                    }
                    .tint(.red)
                    Button(intent: CancelShutdownIntent(spark.id)) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                }
            } else if spark.outlet == .off {
                Button(intent: SwitchOnIntent(spark.id)) {
                    Label("Turn On", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                }
                .tint(.accentColor)
            } else {
                Button(intent: ArmShutdownIntent(spark.id)) {
                    Label("Shut Down", systemImage: "power").frame(maxWidth: .infinity)
                }
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }
}

struct Sparkline: View {
    let points: [SparkPoint]
    let showsAxis: Bool

    private var segments: [(segment: Int, date: Date, watts: Double)] {
        var segment = 0
        var result: [(Int, Date, Double)] = []
        for point in points {
            if let watts = point.watts {
                result.append((segment, point.date, watts))
            } else {
                segment += 1
            }
        }
        return result
    }

    var body: some View {
        Chart(segments, id: \.date) { item in
            AreaMark(x: .value("Time", item.date), y: .value("W", item.watts), series: .value("Segment", item.segment))
                .interpolationMethod(.monotone)
                .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.3), .accentColor.opacity(0.02)],
                                                 startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", item.date), y: .value("W", item.watts), series: .value("Segment", item.segment))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .foregroundStyle(Color.accentColor)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            if showsAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let watts = value.as(Double.self) { Text("\(Int(watts))") }
                    }
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .widgetAccentable()
    }
}

enum WidgetFormat {
    static func number(_ watts: Double?) -> String {
        guard let watts else { return "–" }
        return watts < 10 ? String(format: "%.1f", watts) : String(format: "%.0f", watts)
    }

    static func watts(_ value: Double?) -> String {
        "\(number(value)) W"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

extension ComputerStatus {
    var widgetColor: Color {
        switch self {
        case .online: .green
        case .starting, .shuttingDown: .orange
        case .notResponding: .yellow
        case .off, .outletOff: .secondary
        case .unknown: .red
        }
    }

    var widgetSymbol: String {
        switch self {
        case .online: "checkmark.circle.fill"
        case .starting: "arrow.up.circle.fill"
        case .notResponding: "exclamationmark.circle.fill"
        case .off: "moon.circle.fill"
        case .outletOff: "powerplug.fill"
        case .shuttingDown: "power.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }
}
