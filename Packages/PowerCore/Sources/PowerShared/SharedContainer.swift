import Foundation

public enum AppGroup {
    public static let identifier = "FZ26Z8W5FZ.com.w3joe.gb10power"
    public static let commandNotification = "com.w3joe.gb10power.command"
}

/// Files the app and the widget extension exchange through the App Group container.
public struct SharedContainer: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static func appGroup() -> SharedContainer? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)
            .map(SharedContainer.init(root:))
    }

    public var commands: URL { root.appending(path: "commands", directoryHint: .isDirectory) }
    public var claimed: URL { root.appending(path: "claimed", directoryHint: .isDirectory) }
    public var acks: URL { root.appending(path: "acks", directoryHint: .isDirectory) }
    public var armed: URL { root.appending(path: "armed", directoryHint: .isDirectory) }
    public var snapshot: URL { root.appending(path: "snapshot.json") }
    public var widgetNotice: URL { root.appending(path: "widget-notice.json") }

    public func ensureDirectories() throws {
        for dir in [commands, claimed, acks, armed] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public func writeWidgetNotice(_ notice: ActionNotice) {
        try? write(notice, to: widgetNotice)
    }

    public func readWidgetNotice() -> ActionNotice? {
        read(ActionNotice.self, from: widgetNotice)
    }
}
