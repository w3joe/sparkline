import PowerCore
import PowerShared
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Schedule", systemImage: "clock") { ScheduleSettings() }
            Tab("Tapo Account", systemImage: "person.crop.circle") { TapoSettings() }
            ForEach(SparkID.allCases) { id in
                Tab(model.config.spark(id).name, systemImage: "cpu") { SparkSettings(id: id) }
            }
        }
        .frame(width: 600, height: 640)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.config.monitoringEnabled }, set: { model.setMonitoring($0) })) {
                    Text("Monitor both Sparks")
                    Text("Reads each plug every 10 seconds and keeps this Mac from sleeping while idle.")
                }
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Text("Open at login")
                    if let message = model.loginItemMessage {
                        Text(message).foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text("A MacBook still sleeps with its lid closed unless it's on power with an external display. Nothing is recorded while the Mac is asleep or off.")
            }

            Section("History") {
                LabeledContent("10-second readings", value: "Kept for 24 hours")
                LabeledContent("1-minute averages", value: "Kept for 30 days")
                LabeledContent("Location") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.defaultURL()])
                    }
                }
                if let error = model.storeError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshLoginItem() }
    }
}

struct TapoSettings: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false
    @State private var results: [SparkID: Result<PlugInfo, PlugError>] = [:]

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $username, prompt: Text("name@example.com"))
                    .textContentType(.username)
                SecureField("Password", text: $password, prompt: Text(model.hasCredentials ? "Saved in Keychain" : "Required"))
                    .textContentType(.password)
            } header: {
                Text("Tapo Account")
            } footer: {
                Text("Both P110 plugs must belong to this account. In the Tapo app, turn on Third-Party Compatibility under Me → Third-Party Services.")
            }

            Section {
                HStack {
                    if model.hasCredentials {
                        Label("Saved in your login keychain", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                    Button("Save and Test") {
                        testing = true
                        Task {
                            results = await model.saveCredentials(username: username, password: password)
                            password = ""
                            testing = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(username.isEmpty || password.isEmpty || testing)
                    .keyboardShortcut(.defaultAction)
                }
                ForEach(SparkID.allCases) { id in
                    if let result = results[id] {
                        PlugTestResult(name: model.config.spark(id).name, result: result)
                    }
                }
                if model.authPaused {
                    Callout(text: "A plug rejected the login, so polling is paused. Plugs lock themselves after repeated failures.",
                            symbol: "lock.trianglebadge.exclamationmark.fill", actionTitle: "Retry") { model.retryPolling() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { username = model.tapoUsername }
    }
}

struct PlugTestResult: View {
    let name: String
    let result: Result<PlugInfo, PlugError>

    var body: some View {
        switch result {
        case .success(let info):
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(name) connected")
                    Text("\(info.model) “\(info.nickname)” · firmware \(info.fwVer) · outlet \(info.deviceOn ? "on" : "off")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .failure(let error):
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(name): \(error.summary)")
                    Text(error.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            } icon: {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }
}

struct ScheduleSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ForEach(SparkID.allCases) { id in
                ScheduleSparkSection(id: id)
            }
        }
        .formStyle(.grouped)
    }
}

struct ScheduleSparkSection: View {
    @Environment(AppModel.self) private var model
    let id: SparkID

    private var hours: QuietHours { model.config.spark(id).schedule }

    var body: some View {
        Section {
            Toggle("Shut down when idle", isOn: binding(\.enabled))
            DatePicker("From", selection: timeBinding(\.startMinutes), displayedComponents: .hourAndMinute)
            DatePicker("Until", selection: timeBinding(\.endMinutes), displayedComponents: .hourAndMinute)
            Toggle(isOn: binding(\.stayOff)) {
                Text("Keep off until turned on")
                Text("After the window ends, leave it off. It comes on only when you turn it on.")
            }
            Stepper(value: binding(\.idleMinutes), in: 1...180) {
                LabeledContent("Idle for", value: "\(hours.idleMinutes) min")
            }
            if hours.startMinutes == hours.endMinutes {
                Text("Choose a different start and end. A window can run past midnight.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let line = model.scheduleLine(id) {
                LabeledContent("Now", value: line)
            }
            if let until = hours.holdUntil, until > Date() {
                LabeledContent("Kept on until \(Format.time(until))") {
                    Button("Allow Schedule") { model.clearScheduleHold(id) }
                }
            }
        } header: {
            Text(model.config.spark(id).name)
        } footer: {
            Text(hours.stayOff
                 ? "When the window ends, the Spark stays off until you turn it on. A GPU job or container still keeps it from shutting down. The outlet is switched off only after an SSH shutdown is confirmed."
                 : "When the window ends, the Spark is turned on. A GPU job or container keeps it from shutting down. Turning it on during the window keeps it on until the window ends. The outlet is switched off only after an SSH shutdown is confirmed.")
        }
    }

    private func binding(_ keyPath: WritableKeyPath<QuietHours, Bool>) -> Binding<Bool> {
        Binding(get: { hours[keyPath: keyPath] }, set: { new in
            var next = hours
            next[keyPath: keyPath] = new
            model.saveSchedule(id, next)
        })
    }

    private func binding(_ keyPath: WritableKeyPath<QuietHours, Int>) -> Binding<Int> {
        Binding(get: { hours[keyPath: keyPath] }, set: { new in
            var next = hours
            next[keyPath: keyPath] = new
            model.saveSchedule(id, next)
        })
    }

    private func timeBinding(_ keyPath: WritableKeyPath<QuietHours, Int>) -> Binding<Date> {
        Binding {
            let minutes = hours[keyPath: keyPath]
            return Calendar.current.date(from: DateComponents(hour: minutes / 60, minute: minutes % 60)) ?? Date()
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            var next = hours
            next[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            model.saveSchedule(id, next)
        }
    }
}

struct SparkSettings: View {
    @Environment(AppModel.self) private var model
    let id: SparkID
    @State private var draft = SparkConfig(id: .a)
    @State private var loaded = false
    @State private var plugResult: Result<PlugInfo, PlugError>?
    @State private var testingPlug = false
    @State private var showingSSHSetup = false
    @State private var sshTrusted = false

    private var saved: SparkConfig { model.config.spark(id) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
            }

            Section {
                TextField("IP address", text: $draft.plugIP, prompt: Text("192.168.1.50"))
                LabeledContent("Connection") {
                    HStack {
                        if testingPlug { ProgressView().controlSize(.small) }
                        Button("Test Plug") {
                            testingPlug = true
                            Task {
                                plugResult = await model.testPlug(draft)
                                testingPlug = false
                            }
                        }
                        .disabled(draft.plugIP.isEmpty || testingPlug)
                    }
                }
                if let plugResult {
                    PlugTestResult(name: draft.name, result: plugResult)
                }
            } header: {
                Text("Tapo P110")
            } footer: {
                Text("Reserve this address for the plug in your router so it doesn't change.")
            }

            Section("SSH") {
                TextField("Host", text: $draft.sshHost, prompt: Text("spark-a.local"))
                TextField("User", text: $draft.sshUser, prompt: Text("nvidia"))
                TextField("Port", value: $draft.sshPort, format: .number.grouping(.never))
                LabeledContent("Shutdown access") {
                    HStack {
                        Label(sshTrusted ? "Host key trusted" : "Not set up",
                              systemImage: sshTrusted ? "checkmark.seal.fill" : "exclamationmark.circle")
                            .foregroundStyle(sshTrusted ? .green : .secondary)
                        Button("Set Up SSH…") {
                            commit()
                            showingSSHSetup = true
                        }
                        .disabled(!draft.hasSSH)
                    }
                }
            }

            Section {
                LabeledContent("Powered-down level") {
                    HStack(spacing: 4) {
                        TextField("Watts", value: $draft.offThresholdWatts, format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Text("W").foregroundStyle(.secondary)
                    }
                }
                ThresholdCalibration(id: id, threshold: $draft.offThresholdWatts)
                LabeledContent("Give up after") {
                    HStack(spacing: 4) {
                        TextField("Seconds", value: $draft.shutdownTimeout, format: .number.grouping(.never))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Shutdown")
            } footer: {
                Text("After the Spark accepts a shutdown, its outlet is switched off only once it stays at or below the powered-down level with SSH closed for 30 seconds. If that doesn't happen in time, or SSH fails, the outlet stays on.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            draft = saved
            loaded = true
        }
        .onChange(of: draft) {
            guard loaded else { return }
            scheduleCommit()
        }
        .onDisappear { commit() }
        .task(id: "\(saved.sshHost):\(saved.sshPort):\(showingSSHSetup)") {
            if model.simulate {
                sshTrusted = true
            } else if saved.hasSSH, model.ssh.hasKey {
                sshTrusted = await model.ssh.isPinned(host: saved.sshHost, port: saved.sshPort)
            } else {
                sshTrusted = false
            }
        }
        .sheet(isPresented: $showingSSHSetup) {
            SSHSetupSheet(config: saved)
        }
    }

    @State private var pendingCommit: Task<Void, Never>?

    private func scheduleCommit() {
        pendingCommit?.cancel()
        pendingCommit = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func commit() {
        pendingCommit?.cancel()
        if draft != saved { model.updateSpark(draft) }
    }
}

struct ThresholdCalibration: View {
    @Environment(AppModel.self) private var model
    let id: SparkID
    @Binding var threshold: Double

    var body: some View {
        let state = model.state(id)
        let running = state.sshReachable == true
        LabeledContent {
            Button("Use Current Reading") {
                if let watts = state.watts {
                    threshold = (max(watts + 2, watts * 1.5) * 2).rounded(.up) / 2
                }
            }
            .disabled(state.watts == nil || state.outlet != .on || running)
        } label: {
            Text("Calibrate")
            Text(running
                 ? "Now \(Format.watts(state.watts)). Shut the Spark down by hand first, then use its standby draw."
                 : "Now \(Format.watts(state.watts)). Sets the level to this reading plus a margin.")
        }
    }
}
