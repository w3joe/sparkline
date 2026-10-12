import Charts
import PowerCore
import PowerShared
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var range: ChartRange = .day

    var body: some View {
        ScrollView {
            content.padding(20)
        }
        .frame(minWidth: 860, minHeight: 620)
        .navigationTitle("GB10 Power")
        .navigationSubtitle(model.config.monitoringEnabled ? "Monitoring" : "Monitoring paused")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Range", selection: $range) {
                    ForEach(ChartRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Graph range")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gearshape") { AppWindows.settings(openSettings) }
                    .help("Open Settings")
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.needsSetup {
                Callout(text: "Add your Tapo account and plug addresses to start monitoring.",
                        symbol: "wrench.and.screwdriver.fill", tint: .accentColor,
                        actionTitle: "Open Settings…") { AppWindows.settings(openSettings) }
            }
            if let error = model.storeError {
                Callout(text: error, symbol: "externaldrive.badge.exclamationmark")
            }
            if let notice = model.notice, Date().timeIntervalSince(notice.at) < 600 {
                NoticeView(notice: notice)
            }
            HStack(alignment: .top, spacing: 16) {
                ForEach(SparkID.allCases) { SparkCard(id: $0) }
            }
            .fixedSize(horizontal: false, vertical: true)
            LinksSection()
            PowerChartSection(range: range)
        }
    }
}

struct SparkCard: View {
    @Environment(AppModel.self) private var model
    let id: SparkID

    var body: some View {
        let config = model.config.spark(id)
        let state = model.state(id)
        let probe = model.health.probe(id)
        let checked = model.health.updatedAt != nil || model.simulate
        let activity = ActivityStyle(probe: probe, checked: checked, status: state.computer)

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 8) {
                Text(config.name).font(.title3.weight(.semibold))
                Spacer()
                Badge(text: activity.label, symbol: activity.symbol, tint: activity.tint)
                StatusBadge(status: state.computer)
            }

            HStack(alignment: .lastTextBaseline, spacing: 28) {
                WattsText(watts: state.watts, size: 42)
                Metric(title: "GPU", value: HealthFormat.percent(probe.workload.gpuUtilization))
                Metric(title: "GPU draw", value: Format.watts(probe.workload.gpuWatts))
                Metric(title: "Memory", value: HealthFormat.gigabytes(probe.workload.memoryUsedGB, of: probe.workload.memoryTotalGB))
            }

            HStack(spacing: 22) {
                Metric(title: "Outlet", value: outlet(state.outlet))
                Metric(title: "SSH", value: state.sshReachable.map { $0 ? "Open" : "Closed" } ?? "–")
                Metric(title: "Today", value: state.todayWh.map { Format.energy(Double($0)) } ?? "–")
                Metric(title: "Updated", value: Format.time(state.lastReadingAt))
            }

            WorkloadSection(probe: probe, activity: activity, checked: checked)
            TemperatureRow(reading: probe.thermal)

            if !config.hasPlug {
                Text("No plug address set.").font(.callout).foregroundStyle(.secondary)
            } else if let error = state.error {
                Label(error.errorDescription ?? error.summary, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)

            if let operation = model.operations[id] {
                OperationProgress(text: operation)
                    .frame(minHeight: 28)
            } else {
                SparkActions(id: id, style: .regular)
            }
        }
        .card()
    }

    private func outlet(_ state: OutletState) -> String {
        switch state {
        case .on: "On"
        case .off: "Off"
        case .unknown: "–"
        }
    }
}

struct WorkloadSection: View {
    let probe: SparkProbe
    let activity: ActivityStyle
    let checked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.forward.dottedline.fill")
                    .foregroundStyle(.secondary)
                Text("Running").font(.subheadline.weight(.semibold))
                Spacer()
                if probe.workload.runningCount > 0 {
                    Text(countLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !checked {
                Text("Checking what’s running…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if !probe.reachable {
                Text(probe.thermal.error ?? "Couldn’t reach this Spark.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if probe.workload.runningCount == 0 {
                Label("Idle — no GPU work or containers", systemImage: "pause.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(probe.workload.processes) { process in
                        WorkRow(
                            symbol: "cpu.fill",
                            title: process.name,
                            detail: [HealthFormat.memory(mebibytes: process.memoryMiB), HealthFormat.duration(seconds: process.runningSeconds)]
                                .filter { $0 != "–" }
                                .joined(separator: " · "),
                            help: process.command
                        )
                    }
                    ForEach(probe.workload.containers) { container in
                        WorkRow(
                            symbol: "shippingbox.fill",
                            title: container.name,
                            detail: [shortImage(container.image), container.status]
                                .filter { !$0.isEmpty }
                                .joined(separator: " · "),
                            help: container.image
                        )
                    }
                }
            }
        }
        .tile()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Running, \(activity.label)")
    }

    private var countLabel: String {
        let jobs = probe.workload.processes.count
        let boxes = probe.workload.containers.count
        var parts: [String] = []
        if jobs > 0 { parts.append(jobs == 1 ? "1 GPU job" : "\(jobs) GPU jobs") }
        if boxes > 0 { parts.append(boxes == 1 ? "1 container" : "\(boxes) containers") }
        return parts.joined(separator: " · ")
    }

    private func shortImage(_ image: String) -> String {
        image.split(separator: "/").last.map(String.init) ?? image
    }
}

struct WorkRow: View {
    let symbol: String
    let title: String
    let detail: String
    let help: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(help)
    }
}

struct TemperatureRow: View {
    let reading: ThermalReading

    var body: some View {
        HStack(spacing: 8) {
            TempMetric(title: "GPU", celsius: reading.gpuC)
            TempMetric(title: "SSD", celsius: reading.ssdC)
            TempMetric(title: "NIC", celsius: reading.nicC)
            TempMetric(title: "Board", celsius: reading.boardC)
        }
        .help(reading.error ?? "Live temperatures")
    }
}

struct TempMetric: View {
    let title: String
    let celsius: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(HealthFormat.celsius(celsius))
                .font(.body.weight(.medium).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tile(padding: 10)
    }

    private var color: Color {
        guard let celsius else { return .primary }
        switch TemperatureBand.band(celsius) {
        case .normal: return .primary
        case .warm: return .orange
        case .hot: return .red
        }
    }
}

struct LinksSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Links", symbol: "cable.connector")
            LinkRow(kind: .tenGig)
            LinkRow(kind: .qsfp)
        }
        .card()
    }
}

struct LinkRow: View {
    @Environment(AppModel.self) private var model
    let kind: LinkKind

    var body: some View {
        let health = model.health
        let up = kind == .tenGig ? health.tenGigUp : health.qsfpUp
        HStack(spacing: 12) {
            Text(kind.title).font(.headline)
            Badge(
                text: up ? "Up" : "Down",
                symbol: up ? "checkmark.circle.fill" : "xmark.circle.fill",
                tint: up ? .green : .red
            )
            Spacer(minLength: 8)
            if let result = health.speedResults[kind] {
                Text(HealthFormat.gigabits(result.gigabitsPerSecond))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if let failure = health.testError[kind] {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
            if health.testing == kind {
                ProgressView().controlSize(.small)
            }
            Button("Test Max Speed") { health.testSpeed(kind) }
                .controlSize(.small)
                .disabled(health.testing != nil)
        }
        .tile(padding: 10)
    }
}

struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).monospacedDigit()
        }
    }
}

struct PowerChartSection: View {
    @Environment(AppModel.self) private var model
    let range: ChartRange
    @State private var points: [ChartPoint] = []
    @State private var selected: Date?

    private func name(_ key: ChartSeriesKey) -> String {
        switch key {
        case .spark(let id): model.config.spark(id).name
        case .total: "Total"
        }
    }

    private func color(_ key: ChartSeriesKey) -> Color {
        switch key {
        case .spark(.a): .blue
        case .spark(.b): .orange
        case .total: .gray
        }
    }

    private var sparks: [SparkID] {
        model.config.sparks.filter(\.hasPlug).map(\.id)
    }

    private var seriesKeys: [ChartSeriesKey] {
        sparks.map(ChartSeriesKey.spark) + (sparks.count > 1 ? [.total] : [])
    }

    private var rangeDescription: String {
        switch range {
        case .hour: "Last hour, 10-second readings"
        case .day: "Last 24 hours, 1-minute averages"
        case .week: "Last 7 days, 15-minute averages"
        case .month: "Last 30 days, hourly averages"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Power", symbol: "chart.xyaxis.line", subtitle: rangeDescription)

            if points.isEmpty {
                ContentUnavailableView(
                    "No Readings Yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Readings appear once the plugs answer. History is kept for 30 days.")
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                chart
                stats
            }
        }
        .card()
        .task(id: "\(range.rawValue)-\(model.historyRevision / 2)") {
            load()
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points.filter { range.bucket >= 900 && $0.series != .total }) { p in
                AreaMark(
                    x: .value("Time", p.date),
                    yStart: .value("Min", p.min),
                    yEnd: .value("Max", p.max),
                    series: .value("Band", p.lineID)
                )
                .foregroundStyle(by: .value("Series", name(p.series)))
                .opacity(0.15)
            }
            ForEach(points) { p in
                LineMark(
                    x: .value("Time", p.date),
                    y: .value("Watts", p.watts),
                    series: .value("Line", p.lineID)
                )
                .foregroundStyle(by: .value("Series", name(p.series)))
                .lineStyle(StrokeStyle(lineWidth: p.series == .total ? 1.5 : 2, lineCap: .round, lineJoin: .round,
                                       dash: p.series == .total ? [4, 3] : []))
                .interpolationMethod(.monotone)
            }
            if let selected {
                RuleMark(x: .value("Selected", selected))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        selectionLabel(at: selected)
                    }
            }
        }
        .chartForegroundStyleScale(domain: seriesKeys.map(name), range: seriesKeys.map(color))
        .chartLegend(position: .top, alignment: .trailing)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let watts = value.as(Double.self) { Text("\(Int(watts)) W") }
                }
            }
        }
        .chartXScale(domain: Date().addingTimeInterval(-range.duration)...Date())
        .chartXSelection(value: $selected)
        .frame(height: 300)
    }

    private func selectionLabel(at date: Date) -> some View {
        let nearest = Dictionary(grouping: points, by: \.series).compactMapValues { series in
            series.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(date: range.duration > 86_400 ? .abbreviated : .omitted, time: .shortened))
                .font(.caption.weight(.semibold))
            ForEach(seriesKeys, id: \.self) { key in
                if let p = nearest[key] {
                    HStack(spacing: 6) {
                        Circle().fill(color(key)).frame(width: 6, height: 6)
                        Text(name(key))
                        Spacer(minLength: 12)
                        Text(Format.watts(p.watts)).monospacedDigit()
                    }
                }
            }
        }
        .font(.caption)
        .padding(8)
        .frame(minWidth: 140)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            ForEach(seriesKeys, id: \.self) { key in
                let series = points.filter { $0.series == key }
                let average = series.isEmpty ? nil : series.map(\.watts).reduce(0, +) / Double(series.count)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle().fill(color(key)).frame(width: 8, height: 8)
                        Text(name(key)).font(.callout.weight(.semibold))
                    }
                    HStack(spacing: 18) {
                        Metric(title: "Average", value: Format.watts(average))
                        Metric(title: "Peak", value: Format.watts(series.map(\.max).max()))
                        Metric(title: "Energy", value: Format.energy(ChartSeriesBuilder.energyWh(series, bucket: range.bucket)))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func load() {
        guard let store = model.store else { return }
        let buckets = (try? store.buckets(for: range)) ?? []
        points = ChartSeriesBuilder.points(from: buckets, bucket: range.bucket, sparks: sparks)
    }
}
