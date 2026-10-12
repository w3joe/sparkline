import Foundation
import PowerCore
import PowerShared
import Synchronization

/// Stand-ins for the Sparks' SSH side when the app runs with `--simulate`. Plugs are simulated
/// by `tapo-helper --simulate`; a simulated shutdown drops the plug's reading to 1.5 W.
final class SimulatedLab: Sendable {
    private let down = Mutex<Set<String>>([])

    func isDown(_ host: String) -> Bool { down.withLock { $0.contains(host) } }
    func markDown(_ host: String) { _ = down.withLock { $0.insert(host) } }
    func markUp(_ host: String) { _ = down.withLock { $0.remove(host) } }

    static let defaultConfig = AppConfig(sparks: [
        SparkConfig(id: .a, plugIP: "sim-plug-a", sshHost: "spark-a.sim", sshUser: "nvidia", shutdownTimeout: 120),
        SparkConfig(id: .b, plugIP: "sim-plug-b", sshHost: "spark-b.sim", sshUser: "nvidia", shutdownTimeout: 120),
    ])
}

struct SimulatedShell: RemoteShell {
    let lab: SimulatedLab
    let helper: HelperClient

    func preflight(_ config: SparkConfig) async -> String? {
        config.hasSSH ? nil : "SSH host and user aren't set for \(config.name)."
    }

    func requestShutdown(_ config: SparkConfig) async -> RemoteResult {
        if config.sshHost.contains("fail") { return .failure("Permission denied (publickey).") }
        let lab = lab, helper = helper
        Task {
            try? await Task.sleep(for: .seconds(5))
            lab.markDown(config.sshHost)
            try? await Task.sleep(for: .seconds(5))
            try? await helper.simulatePower(config.id, milliwatts: 1_500)
        }
        return .success("")
    }

    func checkAccess(_ config: SparkConfig) async -> RemoteResult {
        config.sshHost.contains("fail") ? .failure("Permission denied (publickey).") : .success("gb10-ok")
    }
}

struct SimulatedProbe: PortProbe {
    let lab: SimulatedLab

    func isOpen(host: String, port: Int, timeout: Duration) async -> Bool {
        !host.isEmpty && !host.contains("unreachable") && !lab.isDown(host)
    }
}
