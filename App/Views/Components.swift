import PowerCore
import PowerShared
import SwiftUI

extension ComputerStatus {
    var color: Color {
        switch self {
        case .online: .green
        case .starting, .shuttingDown: .orange
        case .notResponding: .yellow
        case .off, .outletOff: .secondary
        case .unknown: .red
        }
    }

    var symbol: String {
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

enum Format {
    static func number(_ watts: Double?) -> String {
        guard let watts else { return "–" }
        return watts < 10 ? String(format: "%.1f", watts) : String(format: "%.0f", watts)
    }

    static func watts(_ value: Double?) -> String {
        "\(number(value)) W"
    }

    static func energy(_ wh: Double) -> String {
        wh >= 1_000 ? String(format: "%.2f kWh", wh / 1_000) : String(format: "%.0f Wh", wh)
    }

    static func time(_ date: Date?) -> String {
        date?.formatted(date: .omitted, time: .shortened) ?? "–"
    }
}

/// A wattage with the unit set smaller, animating as it changes.
struct WattsText: View {
    let watts: Double?
    var size: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(Format.number(watts))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: watts ?? 0))
            Text("W")
                .font(.system(size: size * 0.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .animation(.smooth, value: watts)
        .accessibilityElement(children: .combine)
    }
}

struct StatusBadge: View {
    let status: ComputerStatus

    var body: some View {
        Badge(text: status.label, symbol: status.symbol, tint: status.color)
    }
}

struct Badge: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .contentTransition(.symbolEffect(.replace))
    }
}

/// What a Spark is running, as shown on its card and in the menu.
struct ActivityStyle {
    let label: String
    let symbol: String
    let tint: Color

    @MainActor
    init(probe: SparkProbe, checked: Bool, status: ComputerStatus) {
        if status == .off || status == .outletOff {
            self.init("Powered off", "moon.zzz.fill", .secondary)
        } else if !checked {
            self.init("Checking…", "ellipsis.circle.fill", .secondary)
        } else if !probe.reachable {
            self.init("Unavailable", "questionmark.circle.fill", .secondary)
        } else {
            switch probe.workload.activity {
            case .busy: self.init("Busy", "gearshape.2.fill", .blue)
            case .loaded: self.init("Loaded", "tray.full.fill", .teal)
            case .idle: self.init("Idle", "pause.circle.fill", .secondary)
            }
        }
    }

    private init(_ label: String, _ symbol: String, _ tint: Color) {
        self.label = label
        self.symbol = symbol
        self.tint = tint
    }
}

extension View {
    /// A top-level dashboard section.
    func card(padding: CGFloat = 18) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }

    /// A grouped block inside a card.
    func tile(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct SectionHeader: View {
    let title: String
    let symbol: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct StatusIcon: View {
    let status: ComputerStatus

    var body: some View {
        Image(systemName: status.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(status.color)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(status.label)
    }
}

struct Callout: View {
    let text: String
    let symbol: String
    var tint: Color = .orange
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct NoticeView: View {
    let notice: ActionNotice

    var body: some View {
        Callout(
            text: notice.message,
            symbol: notice.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            tint: notice.success ? .green : .orange
        )
    }
}

struct OperationProgress: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// Turn On and Shut Down for one Spark.
///
/// Turn On is the prominent action. Shut Down is never the default button and always asks
/// first: inline in the compact menu panel, as a confirmation dialog in the dashboard.
struct SparkActions: View {
    enum Style { case compact, regular }

    @Environment(AppModel.self) private var model
    let id: SparkID
    var style: Style = .regular
    @State private var confirmingShutdown = false
    @State private var confirmingCycle = false

    var body: some View {
        let state = model.state(id)
        let config = model.config.spark(id)
        let busy = model.isBusy(id)
        let canTurnOn = !busy && config.hasPlug && state.outlet != .on
        let canShutDown = !busy && config.hasPlug && state.outlet != .off
        let canCycle = !busy && state.outlet == .on && state.computer == .off

        Group {
            if style == .compact && confirmingShutdown {
                HStack(spacing: 8) {
                    Text("Shut down \(config.name)?")
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                    Button("Cancel") { confirmingShutdown = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Shut Down", role: .destructive) {
                        confirmingShutdown = false
                        model.shutDown(id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .task {
                    try? await Task.sleep(for: .seconds(10))
                    confirmingShutdown = false
                }
            } else {
                HStack(spacing: 8) {
                    if style == .regular && canCycle {
                        Button("Power Cycle…", systemImage: "arrow.clockwise") { confirmingCycle = true }
                            .help("Switch the outlet off and on so the Spark starts. Only allowed when it's confirmed off.")
                    }
                    Spacer(minLength: 0)
                    if state.outlet != .off {
                        Button("Shut Down…", systemImage: "power") { confirmingShutdown = true }
                            .disabled(!canShutDown)
                            .help("Shut the Spark down over SSH, then switch its outlet off.")
                    }
                    if state.outlet != .on {
                        Button("Turn On", systemImage: "bolt.fill") { model.switchOn(id) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canTurnOn)
                            .help("Switch the outlet on. The Spark starts when power is applied.")
                    }
                }
            }
        }
        .controlSize(style == .compact ? .small : .regular)
        .confirmationDialog(
            "Shut down \(config.name)?",
            isPresented: Binding(get: { style == .regular && confirmingShutdown }, set: { confirmingShutdown = $0 })
        ) {
            Button("Shut Down", role: .destructive) { model.shutDown(id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(config.name) is asked to shut down over SSH. Its outlet is switched off only after it has powered down. If anything fails, the outlet stays on.")
        }
        .confirmationDialog("Power cycle \(config.name)'s outlet?", isPresented: $confirmingCycle) {
            Button("Power Cycle") { model.powerCycle(id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The outlet is switched off for 5 seconds and back on, so the Spark starts. This only happens if the Spark is confirmed off.")
        }
    }
}

struct CopyableText: View {
    let text: String
    var minHeight: CGFloat = 0
    @State private var copied = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView([.horizontal, .vertical]) {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .padding(.trailing, 64)
            }
            .frame(minHeight: minHeight)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))

            Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            .controlSize(.small)
            .padding(6)
        }
    }
}
