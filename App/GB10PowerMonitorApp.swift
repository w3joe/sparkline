import AppKit
import PowerShared
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Self.model?.start() }
    }
}

@main
struct GB10PowerMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        AppDelegate.model = model
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Sparkline", id: WindowID.dashboard) {
            DashboardView()
                .environment(model)
        }
        .defaultSize(width: 980, height: 780)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum WindowID {
    static let dashboard = "dashboard"
}

struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.operations.isEmpty ? "bolt.fill" : "bolt.badge.clock.fill")
            if let total = model.totalWatts {
                Text("\(Int(total.rounded())) W")
            }
        }
        .task {
            // `--show dashboard` or `--show settings` opens a window at launch.
            let args = CommandLine.arguments
            let requested = args.firstIndex(of: "--show").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            if requested == WindowID.dashboard {
                openWindow(id: WindowID.dashboard)
            } else if requested == "settings" || model.needsSetup {
                openSettings()
            }
            NSApp.activate()
        }
    }
}

/// LSUIElement apps must activate themselves for their windows to come forward.
@MainActor
enum AppWindows {
    static func dashboard(_ openWindow: OpenWindowAction) {
        openWindow(id: WindowID.dashboard)
        NSApp.activate()
    }

    static func settings(_ openSettings: OpenSettingsAction) {
        openSettings()
        NSApp.activate()
    }
}
