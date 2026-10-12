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
        .frame(minWidth: 780, minHeight: 560)
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

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(config.name).font(.title3.weight(.semibold))
                Spacer()
                StatusBadge(status: state.computer)
            }

            WattsText(watts: state.watts, size: 40)

            HStack(spacing: 22) {
                Metric(title: "Outlet", value: outlet(state.outlet))
                Metric(title: "SSH", value: state.sshReachable.map { $0 ? "Open" : "Closed" } ?? "–")
                Metric(title: "Today", value: state.todayWh.map { Format.energy(Double($0)) } ?? "–")
                Metric(title: "Updated", value: Format.time(state.lastReadingAt))
            }

            TemperatureRow(reading: model.health.thermals[id])

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
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    private func outlet(_ state: OutletState) -> String {
        switch state {
        case .on: "On"
        case .off: "Off"
        case .unknown: "–"
        }
    }
}

struct TemperatureRow: View {
    let reading: ThermalReading?

    var body: some View {
        HStack(spacing: 16) {
            TempMetric(title: "GPU", celsius: reading?.gpuC)
            TempMetric(title: "SSD", celsius: reading?.ssdC)
            TempMetric(title: "NIC", celsius: reading?.nicC)
            TempMetric(title: "Board", celsius: reading?.boardC)
        }
        .help(reading?.error ?? "Live temperatures")
    }
}

struct TempMetric: View {
    let title: String
    let celsius: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(HealthFormat.celsius(celsius))
                .font(.callout.monospacedDigit())
                .foregroundStyle(color)
        }
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
        let health = model.health
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Links").font(.title3.weight(.semibold))
                Text(health.updatedAt.map { "Updated \(Format.time($0))" } ?? "Waiting for the first reading")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = health.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).lineLimit(3)
            }
            LinkRow(kind: .tenGig)
            LinkRow(kind: .qsfp)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

struct LinkRow: View {
    @Environment(AppModel.self) private var model
    let kind: LinkKind

    var body: some View {
        let health = model.health
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).font(.headline)
                    Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                status
            }
            HStack(spacing: 22) {
                metrics
            }
            if kind == .qsfp {
                HStack(spacing: 16) {
                    ForEach(HealthMonitor.qsfpPorts, id: \.self) { name in
                        let one = health.spark1.port(name)
                        let two = health.spark2.port(name)
                        Text("\(name) \(portMark(one)) / \(portMark(two))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                if let result = health.speedResults[kind] {
                    Text("Last test \(HealthFormat.gigabits(result.gigabitsPerSecond)) at \(Format.time(result.at))")
                        .font(.callout).foregroundStyle(.secondary)
                } else if let failure = health.testError[kind] {
                    Text(failure).font(.callout).foregroundStyle(.orange).lineLimit(2)
                }
                Spacer()
                if health.testing == kind {
                    ProgressView().controlSize(.small)
                }
                Button("Test Max Speed") { health.testSpeed(kind) }
                    .disabled(health.testing != nil)
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var status: some View {
        let up = kind == .tenGig ? model.health.tenGigUp : model.health.qsfpUp
        Label(up ? "Up" : "Down", systemImage: up ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(up ? .green : .red)
    }

    @ViewBuilder
    private var metrics: some View {
        let health = model.health
        switch kind {
        case .tenGig:
            Metric(title: "Speed", value: HealthFormat.megabits(health.localEthernet.megabitsPerSecond ?? health.spark1.port(HealthMonitor.tenGigPort)?.megabitsPerSecond))
            Metric(title: "Ping", value: HealthFormat.ping(health.tenGigPing))
            Metric(title: "Mac", value: health.localEthernet.address ?? "No address")
            Metric(title: "Spark 1", value: HealthMonitor.sparkTenGigAddress)
        case .qsfp:
            let speed = HealthMonitor.qsfpPorts.compactMap { health.spark1.port($0)?.megabitsPerSecond }.max()
            Metric(title: "Speed", value: HealthFormat.megabits(speed))
            Metric(title: "Ping", value: HealthFormat.ping(health.spark1.pingMilliseconds))
            Metric(title: "Path", value: "192.168.177.11 to .12")
        }
    }

    private func portMark(_ port: PortReading?) -> String {
        guard let port else { return "–" }
        return port.up ? "up" : "down"
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Power").font(.title3.weight(.semibold))
                Text(rangeDescription).font(.callout).foregroundStyle(.secondary)
            }

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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
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
