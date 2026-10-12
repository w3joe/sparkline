import AppIntents
import Charts
import PowerShared
import SwiftUI
import WidgetKit

struct WidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                content(snapshot)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Sparkline", systemImage: "bolt.fill")
                        .font(.headline)
                        .widgetAccentable()
                    Spacer()
                    Text("Open Sparkline to start monitoring.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .id(entry.snapshot?.generatedAt ?? entry.date)
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetSnapshot) -> some View {
        let sparks = entry.choice.ids.compactMap(snapshot.spark)
        switch (family, sparks.count) {
        case (.systemLarge, 1):
            SingleSparkLarge(spark: sparks[0], entry: entry, snapshot: snapshot)
        case (.systemLarge, _):
            BothSparksLarge(sparks: sparks, entry: entry, snapshot: snapshot)
        case (_, 1):
            SingleSparkMedium(spark: sparks[0], entry: entry, snapshot: snapshot)
        default:
            BothSparksMedium(sparks: sparks, entry: entry, snapshot: snapshot)
        }
    }
}

// MARK: Square

private struct SingleSparkLarge: View {
    let spark: SparkSnapshot
    let entry: Entry
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SparkHeader(spark: spark)
            Watts(watts: spark.watts, size: 44)
            Text(spark.runningSummary)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 16) {
                MiniStat(title: "GPU", value: WidgetFormat.percent(spark.gpuUtilization))
                MiniStat(title: "Temp", value: WidgetFormat.celsius(spark.gpuCelsius))
                MiniStat(title: "GPU draw", value: WidgetFormat.watts(spark.gpuWatts))
                MiniStat(title: "Outlet", value: spark.outlet == .on ? "On" : spark.outlet == .off ? "Off" : "–")
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Last hour")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Sparkline(points: spark.sparkline, showsAxis: true)
                    .frame(maxHeight: .infinity)
            }

            StatusLine(spark: spark, entry: entry, snapshot: snapshot)
            PrimaryAction(spark: spark, entry: entry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct BothSparksLarge: View {
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
            HStack(alignment: .firstTextBaseline) {
                Label("Sparkline", systemImage: "bolt.fill")
                    .font(.headline)
                    .widgetAccentable()
                Spacer()
                Watts(watts: total, size: 28)
            }
            .padding(.bottom, 10)

            ForEach(Array(sparks.enumerated()), id: \.element.id) { index, spark in
                if index > 0 {
                    Divider().padding(.vertical, 10)
                }
                SparkListRow(spark: spark, entry: entry)
            }

            Spacer(minLength: 8)
            FooterLine(entry: entry, snapshot: snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct SparkListRow: View {
    let spark: SparkSnapshot
    let entry: Entry

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    StatusSymbol(status: spark.computer)
                    Text(spark.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                Text(spark.runningSummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("GPU \(WidgetFormat.percent(spark.gpuUtilization))  ·  \(WidgetFormat.celsius(spark.gpuCelsius))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                Watts(watts: spark.watts, size: 22)
                PrimaryAction(spark: spark, entry: entry, fillsWidth: false)
            }
        }
    }
}

private struct SingleSparkMedium: View {
    let spark: SparkSnapshot
    let entry: Entry
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                SparkHeader(spark: spark)
                Watts(watts: spark.watts, size: 32)
                Text(spark.runningSummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    MiniStat(title: "GPU", value: WidgetFormat.percent(spark.gpuUtilization))
                    MiniStat(title: "Temp", value: WidgetFormat.celsius(spark.gpuCelsius))
                }
                Spacer(minLength: 4)
                StatusLine(spark: spark, entry: entry, snapshot: snapshot)
                PrimaryAction(spark: spark, entry: entry)
            }
            .frame(minWidth: 150)
            Sparkline(points: spark.sparkline, showsAxis: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct BothSparksMedium: View {
    let sparks: [SparkSnapshot]
    let entry: Entry
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(sparks.enumerated()), id: \.element.id) { index, spark in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    SparkHeader(spark: spark)
                    Watts(watts: spark.watts, size: 26)
                    Text(spark.runningSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        MiniStat(title: "GPU", value: WidgetFormat.percent(spark.gpuUtilization))
                        MiniStat(title: "Temp", value: WidgetFormat.celsius(spark.gpuCelsius))
                    }
                    Sparkline(points: spark.sparkline, showsAxis: false)
                        .frame(height: 22)
                    Spacer(minLength: 0)
                    PrimaryAction(spark: spark, entry: entry)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
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

private struct MiniStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
    var fillsWidth = true

    var body: some View {
        Group {
            if !spark.configured || spark.operation != nil || spark.outlet == .unknown {
                Color.clear.frame(height: 22)
            } else if entry.isArmed(spark.id) {
                HStack(spacing: 4) {
                    Button(intent: ConfirmShutdownIntent(spark.id)) {
                        Text("Confirm").frame(maxWidth: fillsWidth ? .infinity : nil)
                    }
                    .tint(.red)
                    Button(intent: CancelShutdownIntent(spark.id)) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                }
            } else if spark.outlet == .off {
                Button(intent: SwitchOnIntent(spark.id)) {
                    label("Turn On", "bolt.fill")
                }
                .tint(.accentColor)
            } else {
                Button(intent: ArmShutdownIntent(spark.id)) {
                    label("Shut Down", "power")
                }
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }

    @ViewBuilder
    private func label(_ title: String, _ symbol: String) -> some View {
        if fillsWidth {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity)
        } else {
            Label(title, systemImage: symbol)
        }
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
                .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.18), .accentColor.opacity(0.02)],
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

    static func percent(_ value: Int?) -> String {
        guard let value else { return "–" }
        return "\(value)%"
    }

    static func celsius(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.0f°", value)
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

