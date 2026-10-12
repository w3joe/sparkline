import AppIntents
import PowerShared
import WidgetKit

enum SparkChoice: String, AppEnum {
    case a, b, both

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Spark"
    static let caseDisplayRepresentations: [SparkChoice: DisplayRepresentation] = [
        .a: "Spark A",
        .b: "Spark B",
        .both: "Both Sparks",
    ]

    var ids: [SparkID] {
        switch self {
        case .a: [.a]
        case .b: [.b]
        case .both: [.a, .b]
        }
    }
}

enum SparkTarget: String, AppEnum {
    case a, b

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Spark"
    static let caseDisplayRepresentations: [SparkTarget: DisplayRepresentation] = [.a: "Spark A", .b: "Spark B"]

    init(_ id: SparkID) {
        self = id == .a ? .a : .b
    }

    var id: SparkID { self == .a ? .a : .b }
}

struct SelectSparkIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Spark"
    static let description = IntentDescription("Pick which DGX Spark the widget shows.")

    @Parameter(title: "Spark", default: .both)
    var spark: SparkChoice

    init() {}
}

enum WidgetActions {
    /// Hands the action to the running app. The outcome is shown by the widget as a notice;
    /// if the app isn't running, the command is withdrawn and never runs later.
    static func send(_ action: PowerAction, to spark: SparkID) async {
        guard let container = SharedContainer.appGroup() else { return }
        let bus = CommandBus(container: container)
        do {
            let ack = try await bus.send(spark: spark, action: action)
            container.writeWidgetNotice(ActionNotice(spark: spark, message: ack.message, success: true))
        } catch {
            container.writeWidgetNotice(ActionNotice(spark: spark, message: error.localizedDescription, success: false))
        }
    }

    static var arming: ShutdownArming? {
        SharedContainer.appGroup().map { ShutdownArming(container: $0) }
    }
}

struct SwitchOnIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch Spark On"
    static let isDiscoverable = false

    @Parameter(title: "Spark")
    var spark: SparkTarget

    init() {}

    init(_ id: SparkID) {
        spark = SparkTarget(id)
    }

    func perform() async throws -> some IntentResult {
        await WidgetActions.send(.on, to: spark.id)
        return .result()
    }
}

struct ArmShutdownIntent: AppIntent {
    static let title: LocalizedStringResource = "Prepare Shut Down"
    static let isDiscoverable = false

    @Parameter(title: "Spark")
    var spark: SparkTarget

    init() {}

    init(_ id: SparkID) {
        spark = SparkTarget(id)
    }

    func perform() async throws -> some IntentResult {
        try WidgetActions.arming?.arm(spark.id, for: 10)
        return .result()
    }
}

struct ConfirmShutdownIntent: AppIntent {
    static let title: LocalizedStringResource = "Shut Down Spark"
    static let isDiscoverable = false

    @Parameter(title: "Spark")
    var spark: SparkTarget

    init() {}

    init(_ id: SparkID) {
        spark = SparkTarget(id)
    }

    func perform() async throws -> some IntentResult {
        guard let arming = WidgetActions.arming, arming.armedUntil(spark.id) != nil else {
            SharedContainer.appGroup()?.writeWidgetNotice(
                ActionNotice(spark: spark.id, message: "Confirmation expired. Tap Shut down again.", success: false)
            )
            return .result()
        }
        arming.disarm(spark.id)
        await WidgetActions.send(.shutDown, to: spark.id)
        return .result()
    }
}

struct CancelShutdownIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Shut Down"
    static let isDiscoverable = false

    @Parameter(title: "Spark")
    var spark: SparkTarget

    init() {}

    init(_ id: SparkID) {
        spark = SparkTarget(id)
    }

    func perform() async throws -> some IntentResult {
        WidgetActions.arming?.disarm(spark.id)
        return .result()
    }
}
