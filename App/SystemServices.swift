import AppKit
import Foundation
import Network
import ServiceManagement

/// Holds an activity assertion that stops idle system sleep and App Nap while monitoring.
@MainActor
final class KeepAwake {
    private var activity: (any NSObjectProtocol)?

    var isActive: Bool { activity != nil }

    func begin() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Monitoring DGX Spark power"
        )
    }

    func end() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

/// Reports when the network comes back after an outage, and when the Mac wakes from sleep.
@MainActor
final class NetworkWatcher {
    private let monitor = NWPathMonitor()
    private var wasSatisfied = true
    private var wakeObserver: (any NSObjectProtocol)?
    private let onRecovered: @MainActor () -> Void
    private let onChange: @MainActor (Bool) -> Void

    init(onChange: @escaping @MainActor (Bool) -> Void, onRecovered: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        self.onRecovered = onRecovered
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.update(satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "gb10.network"))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onRecovered() }
        }
    }

    private func update(_ satisfied: Bool) {
        defer { wasSatisfied = satisfied }
        onChange(satisfied)
        if satisfied && !wasSatisfied { onRecovered() }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusDescription: String? {
        switch SMAppService.mainApp.status {
        case .requiresApproval: "Allow Sparkline in System Settings → General → Login Items."
        case .notFound: "macOS can't find the app to register. Install it in /Applications first."
        default: nil
        }
    }

    static var isInstalledInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Forwards a Darwin notification (posted by the widget extension) to the main actor.
final class DarwinObserver: @unchecked Sendable {
    private let handler: @MainActor @Sendable () -> Void

    init(name: String, handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in me.handler() }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque()
        )
    }
}
