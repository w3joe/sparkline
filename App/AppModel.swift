import AppKit
import Foundation
import Observation
import PowerCore
import PowerShared
import WidgetKit

@MainActor
@Observable
final class AppModel {
    let simulate: Bool
    var config: AppConfig
    var states: [SparkID: SparkLiveState] = [:]
    var operations: [SparkID: String] = [:]
    var notice: ActionNotice?
    var tapoUsername: String
    var hasCredentials: Bool
    var launchAtLogin = false
    var loginItemMessage: String?
    var networkAvailable = true
    var storeError: String?
    /// Bumped whenever new samples land, so charts reload.
    var historyRevision = 0

    @ObservationIgnored let store: HistoryStore?
    @ObservationIgnored let helper: HelperClient
    @ObservationIgnored let ssh: SSHEnvironment
    @ObservationIgnored let shell: any RemoteShell
    @ObservationIgnored let probe: any PortProbe
    @ObservationIgnored private(set) var monitor: Monitor!
    @ObservationIgnored private(set) var controller: PowerController!
    let health: HealthMonitor
    /// Bumped when link or temperature readings change.
    var healthRevision = 0

    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private let credentialStore = CredentialStore()
    @ObservationIgnored private let container = SharedContainer.appGroup()
    @ObservationIgnored private let bus: CommandBus?
    @ObservationIgnored private let lab = SimulatedLab()
    @ObservationIgnored private let keepAwake = KeepAwake()
    @ObservationIgnored private var networkWatcher: NetworkWatcher?
    @ObservationIgnored private var commandObserver: DarwinObserver?
    @ObservationIgnored private var operationTokens: [SparkID: UUID] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var publishScheduled = false
    @ObservationIgnored private var lastWidgetSignature = ""
    @ObservationIgnored private var lastWidgetReload = Date.distantPast

    init() {
        simulate = CommandLine.arguments.contains("--simulate")
        configStore = ConfigStore(suiteName: simulate ? "com.w3joe.GB10PowerMonitor.simulation" : nil)
        var loaded = configStore.load()
        if simulate, !loaded.sparks.contains(where: \.hasPlug) {
            loaded = SimulatedLab.defaultConfig
        }
        config = loaded

        let credentials = simulate ? TapoCredentials(username: "simulated@example.com", password: "sim") : credentialStore.load()
        tapoUsername = credentials?.username ?? ""
        hasCredentials = credentials != nil

        do {
            let url = HistoryStore.defaultURL()
            store = try HistoryStore(url: simulate ? url.deletingLastPathComponent().appending(path: "history-sim.sqlite") : url)
        } catch {
            store = nil
            storeError = "History is unavailable: \(error.localizedDescription)"
        }

        helper = HelperClient.bundled(simulate: simulate)
        ssh = SSHEnvironment.standard()
        if simulate {
            shell = SimulatedShell(lab: lab, helper: helper)
            probe = SimulatedProbe(lab: lab)
        } else {
            shell = SSHShell(environment: ssh)
            probe = TCPPortProbe()
        }
        bus = container.map { CommandBus(container: $0) }

        let health = HealthMonitor(enabled: !simulate, onChange: {})
        self.health = health
        health.onChange = { [weak self] in
            self?.healthRevision &+= 1
            self?.schedulePublish()
        }

        monitor = Monitor(plug: helper, probe: probe, store: store) { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
        controller = PowerController(plug: helper, shell: shell, probe: probe)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true

        try? container?.ensureDirectories()
        bus?.purge()
        setUpLoginItem()

        networkWatcher = NetworkWatcher(
            onChange: { [weak self] available in self?.networkAvailable = available },
            onRecovered: { [weak self] in self?.networkRecovered() }
        )
        networkWatcher?.start()

        commandObserver = DarwinObserver(name: AppGroup.commandNotification) { [weak self] in
            self?.processCommands()
        }

        Task { [weak self] in
            while let self {
                self.processCommands()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        Task { [weak self] in
            while let self {
                self.pruneHistory()
                try? await Task.sleep(for: .seconds(3_600))
            }
        }

        Task {
            if let credentials = currentCredentials() {
                try? await helper.configure(credentials)
            }
            applyMonitoring()
            health.start()
        }
    }

    private func currentCredentials() -> TapoCredentials? {
        simulate ? TapoCredentials(username: "simulated@example.com", password: "sim") : credentialStore.load()
    }

    func applyMonitoring() {
        configStore.save(config)
        if config.monitoringEnabled {
            keepAwake.begin()
            Task { await monitor.start(config.sparks) }
        } else {
            keepAwake.end()
            Task { await monitor.stop() }
        }
        publishWidgets(force: true)
    }

    func setMonitoring(_ enabled: Bool) {
        config.monitoringEnabled = enabled
        applyMonitoring()
    }

    private func networkRecovered() {
        guard config.monitoringEnabled else { return }
        Task { await monitor.networkRecovered() }
    }

    private func pruneHistory() {
        do {
            try store?.prune()
        } catch {
            storeError = "Couldn't prune history: \(error.localizedDescription)"
        }
    }

    // MARK: Monitor updates

    private func apply(_ state: SparkLiveState) {
        states[state.id] = state
        historyRevision &+= 1
        schedulePublish()
    }

    func state(_ id: SparkID) -> SparkLiveState {
        states[id] ?? SparkLiveState(id: id)
    }

    var totalWatts: Double? {
        let values = config.sparks.filter(\.hasPlug).map { state($0.id).watts }
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(0, +)
    }

    var needsSetup: Bool {
        !hasCredentials || !config.sparks.contains(where: \.hasPlug)
    }

    var authPaused: Bool {
        states.values.contains { $0.authPaused }
    }

    func retryPolling() {
        Task { await monitor.resume() }
    }

    // MARK: Configuration

    func updateSpark(_ spark: SparkConfig) {
        config.update(spark)
        applyMonitoring()
    }

    /// Saves the Tapo account and checks it against each configured plug.
    func saveCredentials(username: String, password: String) async -> [SparkID: Result<PlugInfo, PlugError>] {
        let credentials = TapoCredentials(username: username, password: password)
        do {
            if !simulate { try credentialStore.save(credentials) }
            tapoUsername = username
            hasCredentials = true
            try await helper.configure(credentials)
        } catch {
            return Dictionary(uniqueKeysWithValues: config.sparks.map {
                ($0.id, .failure(PlugError(.notConfigured, error.localizedDescription)))
            })
        }
        var results: [SparkID: Result<PlugInfo, PlugError>] = [:]
        await withTaskGroup(of: (SparkID, Result<PlugInfo, PlugError>).self) { group in
            for spark in config.sparks where spark.hasPlug {
                group.addTask { [helper] in
                    do {
                        return (spark.id, .success(try await helper.info(spark.id, ip: spark.plugIP)))
                    } catch {
                        return (spark.id, .failure(PlugError.wrap(error)))
                    }
                }
            }
            for await (id, result) in group { results[id] = result }
        }
        await monitor.resume()
        return results
    }

    func testPlug(_ spark: SparkConfig) async -> Result<PlugInfo, PlugError> {
        do {
            return .success(try await helper.info(spark.id, ip: spark.plugIP))
        } catch {
            return .failure(PlugError.wrap(error))
        }
    }

    // MARK: Actions

    func isBusy(_ id: SparkID) -> Bool { operations[id] != nil }

    func perform(_ action: PowerAction, _ id: SparkID) {
        switch action {
        case .on: switchOn(id)
        case .shutDown: shutDown(id)
        }
    }

    func switchOn(_ id: SparkID) {
        run(id, overlay: nil, initial: "Switching on…") { controller, config, progress in
            await controller.switchOn(config, progress: progress)
        } completion: { [weak self] outcome, config in
            guard let self, outcome.success else { return }
            await self.monitor.noteSwitchedOn(id)
            if self.simulate { self.lab.markUp(config.sshHost) }
        }
    }

    func shutDown(_ id: SparkID) {
        run(id, overlay: .shuttingDown, initial: "Shutting down…") { controller, config, progress in
            await controller.shutDown(config, progress: progress)
        } completion: { _, _ in }
    }

    func powerCycle(_ id: SparkID) {
        run(id, overlay: nil, initial: "Power cycling…") { controller, config, progress in
            await controller.powerCycle(config, progress: progress)
        } completion: { [weak self] outcome, config in
            guard let self, outcome.success else { return }
            await self.monitor.noteSwitchedOn(id)
            if self.simulate { self.lab.markUp(config.sshHost) }
        }
    }

    private func run(
        _ id: SparkID,
        overlay: ComputerStatus?,
        initial: String,
        _ body: @escaping @Sendable (PowerController, SparkConfig, @escaping @Sendable (ShutdownPhase) -> Void) async -> ActionOutcome,
        completion: @escaping @MainActor (ActionOutcome, SparkConfig) async -> Void
    ) {
        guard operations[id] == nil else {
            notice = ActionNotice(spark: id, message: "\(config.spark(id).name) already has an action in progress.", success: false)
            return
        }
        let token = UUID()
        operationTokens[id] = token
        operations[id] = initial
        let sparkConfig = config.spark(id)
        publishWidgets(force: true)

        Task {
            if let overlay { await monitor.setOperation(id, overlay) }
            let progress: @Sendable (ShutdownPhase) -> Void = { phase in
                Task { @MainActor in
                    guard self.operationTokens[id] == token else { return }
                    self.operations[id] = phase.label
                    self.schedulePublish()
                }
            }
            let outcome = await body(controller, sparkConfig, progress)
            if overlay != nil { await monitor.setOperation(id, nil) }
            await completion(outcome, sparkConfig)
            operationTokens[id] = nil
            operations[id] = nil
            notice = ActionNotice(spark: id, message: outcome.message, success: outcome.success)
            await monitor.sampleOnce(id)
            publishWidgets(force: true)
        }
    }

    // MARK: Widget commands

    func processCommands() {
        guard let bus else { return }
        for command in bus.claimPending() {
            let spark = config.spark(command.spark)
            if !spark.hasPlug {
                bus.acknowledge(command, accepted: false, message: "\(spark.name) isn't set up yet.")
            } else if isBusy(command.spark) {
                bus.acknowledge(command, accepted: false, message: "\(spark.name) already has an action in progress.")
            } else {
                bus.acknowledge(command, accepted: true, message: "\(command.action.label) requested for \(spark.name).")
                perform(command.action, command.spark)
            }
        }
    }

    // MARK: Widget snapshot

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            publishScheduled = false
            publishWidgets(force: false)
        }
    }

    func publishWidgets(force: Bool) {
        guard let container else { return }
        let now = Date()
        let buckets = (try? store?.buckets(for: .hour, now: now)) ?? []
        let sparks = SparkID.allCases.map { id -> SparkSnapshot in
            let spark = config.spark(id)
            let state = state(id)
            let probe = health.probe(id)
            let poweredOff = state.computer == .off || state.computer == .outletOff
            let activity: WorkActivity = {
                if poweredOff || !probe.reachable { return .idle }
                switch probe.workload.activity {
                case .busy: return .busy
                case .loaded: return .loaded
                case .idle: return .idle
                }
            }()
            return SparkSnapshot(
                id: id,
                name: spark.name,
                configured: spark.hasPlug,
                outlet: state.outlet,
                computer: state.computer,
                watts: state.watts,
                readingAt: state.lastReadingAt,
                error: state.error?.summary,
                operation: operations[id],
                sparkline: ChartSeriesBuilder.sparkline(from: buckets, spark: id, end: now, span: 3_600, slots: 30),
                gpuUtilization: probe.workload.gpuUtilization,
                gpuCelsius: probe.thermal.gpuC,
                gpuWatts: probe.workload.gpuWatts,
                activity: activity,
                jobName: probe.workload.processes.first?.name ?? probe.workload.containers.first?.name,
                jobCount: probe.workload.processes.count,
                containerCount: probe.workload.containers.count
            )
        }
        let snapshot = WidgetSnapshot(generatedAt: now, monitoring: config.monitoringEnabled, sparks: sparks, notice: notice)
        try? snapshot.write(to: container)

        let signature = sparks.map {
            "\($0.name)|\($0.configured)|\($0.outlet)|\($0.computer)|\($0.error ?? "")|\($0.operation ?? "")|\($0.activity)|\($0.jobName ?? "")|\($0.gpuUtilization ?? -1)|\(Int(($0.watts ?? 0).rounded()))|\($0.gpuCelsius.map { Int($0) } ?? -1)"
        }
            .joined(separator: ";") + "|\(notice?.at.timeIntervalSince1970 ?? 0)|\(config.monitoringEnabled)"
        if force || signature != lastWidgetSignature {
            lastWidgetSignature = signature
            lastWidgetReload = now
            WidgetCenter.shared.reloadTimelines(ofKind: "SparkPowerWidget")
            WidgetCenter.shared.reloadTimelines(ofKind: "SparkPowerSquare")
        }
    }

    // MARK: Login item

    private func setUpLoginItem() {
        let key = "loginItemConfigured.v1"
        if !UserDefaults.standard.bool(forKey: key), LoginItem.isInstalledInApplications, !simulate {
            try? LoginItem.setEnabled(true)
            UserDefaults.standard.set(true, forKey: key)
        }
        refreshLoginItem()
    }

    func refreshLoginItem() {
        launchAtLogin = LoginItem.isEnabled
        loginItemMessage = LoginItem.statusDescription
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            loginItemMessage = "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = LoginItem.isEnabled
        if loginItemMessage == nil || LoginItem.statusDescription != nil {
            loginItemMessage = LoginItem.statusDescription
        }
        if enabled, !LoginItem.isInstalledInApplications {
            loginItemMessage = "The app isn't in /Applications. Run `make install` so the login item points at a stable copy."
        }
    }

    var keepsMacAwake: Bool { keepAwake.isActive }
}
