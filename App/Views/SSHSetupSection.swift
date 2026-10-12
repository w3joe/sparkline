import PowerCore
import PowerShared
import SwiftUI

/// Step-by-step SSH setup for one Spark: app key, host key verification, Spark-side commands, test.
struct SSHSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let config: SparkConfig

    @State private var publicKey: String?
    @State private var scanned: ScannedHostKey?
    @State private var pinned = false
    @State private var busy = false
    @State private var message: String?
    @State private var testResult: RemoteResult?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up SSH for \(config.name)").font(.title2.weight(.semibold))
                Text("The app uses its own key and known-hosts file, separate from ~/.ssh. On the Spark, the key can only run a check and `systemctl poweroff`.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)

            Form {
                Section {
                    if let publicKey {
                        CopyableText(text: publicKey)
                    } else {
                        HStack {
                            Text("Create a dedicated ed25519 key for this app.")
                            Spacer()
                            Button("Create Key") { run { publicKey = try await model.ssh.ensureKey() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } header: {
                    StepHeader(number: 1, title: "App Key", done: publicKey != nil)
                }

                Section {
                    Text("On the Spark itself, run this and keep the output handy:")
                    CopyableText(text: SparkSetupScript.fingerprintCommand)
                    HStack {
                        Text("Then fetch the key \(config.sshHost) presents over the network.")
                        Spacer()
                        Button(pinned ? "Scan Again" : "Scan Host Key") {
                            run { scanned = try await model.ssh.scanHostKey(host: config.sshHost, port: config.sshPort) }
                        }
                        .disabled(busy)
                    }
                    if let scanned {
                        CopyableText(text: scanned.fingerprints.joined(separator: "\n"))
                        HStack {
                            Text("Trust it only if the fingerprints match exactly.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Fingerprints Match") {
                                run {
                                    try await model.ssh.pin(scanned, host: config.sshHost, port: config.sshPort)
                                    self.scanned = nil
                                    pinned = true
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } header: {
                    StepHeader(number: 2, title: "Verify the Spark's Host Key", done: pinned)
                }

                Section {
                    if let publicKey {
                        Text("Run these on the Spark as \(config.sshUser). They add a restricted command, a sudo rule for `systemctl poweroff` only, and the app's key limited to that command.")
                            .fixedSize(horizontal: false, vertical: true)
                        CopyableText(text: SparkSetupScript.render(user: config.sshUser, publicKey: publicKey), minHeight: 170)
                    } else {
                        Text("Create the app key first.").foregroundStyle(.secondary)
                    }
                } header: {
                    StepHeader(number: 3, title: "Allow Shutdown on the Spark", done: testResult?.succeeded == true)
                }

                Section {
                    HStack {
                        Text("Checks the key, host key and sudo rule. Nothing is shut down.")
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        Button("Test Access") { run { testResult = await model.shell.checkAccess(config) } }
                            .disabled(busy || publicKey == nil || !pinned)
                    }
                    switch testResult {
                    case .success:
                        Label("Everything works. \(config.name) can be shut down from this Mac.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let error):
                        Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    case nil:
                        EmptyView()
                    }
                } header: {
                    StepHeader(number: 4, title: "Test", done: testResult?.succeeded == true)
                }

                if let message {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 720)
        .task { await refresh() }
    }

    private func refresh() async {
        publicKey = model.ssh.publicKey()
        pinned = await model.ssh.isPinned(host: config.sshHost, port: config.sshPort)
        if model.simulate {
            pinned = true
            publicKey = publicKey ?? "ssh-ed25519 AAAA-simulated gb10-power-monitor"
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        message = nil
        Task {
            do {
                try await work()
            } catch {
                message = error.localizedDescription
            }
            busy = false
        }
    }
}

private struct StepHeader: View {
    let number: Int
    let title: String
    let done: Bool

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(done ? .green : .secondary)
        }
    }
}
