import PowerCore
import PowerShared
import SwiftUI

struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            VStack(spacing: 8) {
                callouts
                ForEach(SparkID.allCases) { SparkMenuRow(id: $0) }
                if let notice = model.notice, Date().timeIntervalSince(notice.at) < 600 {
                    NoticeView(notice: notice)
                }
            }
            .padding(.horizontal, 10)

            Divider().padding(.top, 12)

            Toggle(isOn: Binding(get: { model.config.monitoringEnabled }, set: { model.setMonitoring($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Monitoring")
                    Text("Reads both plugs and keeps this Mac awake")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            HStack(spacing: 4) {
                FooterButton(title: "Dashboard", symbol: "chart.xyaxis.line") { AppWindows.dashboard(openWindow) }
                FooterButton(title: "Settings…", symbol: "gearshape") { AppWindows.settings(openSettings) }
                Spacer()
                FooterButton(title: "Quit", symbol: nil) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("GB10 Power").font(.headline)
                    if model.simulate {
                        Text("Simulation")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.15), in: Capsule())
                    }
                }
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if model.totalWatts != nil {
                WattsText(watts: model.totalWatts, size: 22)
                    .help("Combined draw of both Sparks")
            }
        }
    }

    private var subtitle: String {
        if !model.config.monitoringEnabled { return "Monitoring paused" }
        if model.totalWatts != nil { return "Total draw" }
        return "Monitoring"
    }

    @ViewBuilder
    private var callouts: some View {
        if model.needsSetup {
            Callout(text: "Add your Tapo account and plug addresses to start.", symbol: "wrench.and.screwdriver.fill",
                    tint: .accentColor, actionTitle: "Set Up…") { AppWindows.settings(openSettings) }
        }
        if model.authPaused {
            Callout(text: "Tapo rejected the login, so polling is paused.", symbol: "lock.trianglebadge.exclamationmark.fill",
                    actionTitle: "Retry") { model.retryPolling() }
        }
        if !model.networkAvailable {
            Callout(text: "No network. Readings resume when it's back.", symbol: "wifi.slash")
        }
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Label(title, systemImage: symbol)
                } else {
                    Text(title)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SparkMenuRow: View {
    @Environment(AppModel.self) private var model
    let id: SparkID

    var body: some View {
        let config = model.config.spark(id)
        let state = model.state(id)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                StatusIcon(status: state.computer)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(config.name).font(.headline)
                    Text(detail(state, config: config))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                WattsText(watts: state.watts, size: 22)
            }

            if config.hasPlug, let error = state.error {
                Label(error.errorDescription ?? error.summary, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            if let operation = model.operations[id] {
                OperationProgress(text: operation)
            } else if config.hasPlug {
                SparkActions(id: id, style: .compact)
            }
        }
        .padding(12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func detail(_ state: SparkLiveState, config: SparkConfig) -> String {
        guard config.hasPlug else { return "Not set up" }
        var parts = [state.computer.label]
        if state.outlet != .unknown, state.computer != .outletOff { parts.append(state.outlet.label) }
        if let at = state.lastReadingAt { parts.append(Format.time(at)) }
        return parts.joined(separator: " · ")
    }
}
