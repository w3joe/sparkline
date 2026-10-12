import Foundation
import Observation
import PowerCore
import PowerShared

/// Polls link state and temperatures over the NVIDIA Sync SSH login, and runs iperf3 on demand.
/// The power-off key is never used here.
@MainActor
@Observable
final class HealthMonitor {
    static let tenGigAddress = "192.168.49.1"
    static let sparkTenGigAddress = "192.168.49.2"
    static let qsfpTarget = "192.168.177.12"
    static let qsfpPorts = ["enp1s0f0np0", "enP2p1s0f0np0"]
    static let tenGigPort = "enP7s7"

    private let sshConfig: String
    private let enabled: Bool
    var onChange: () -> Void

    private(set) var thermals: [SparkID: ThermalReading] = [:]
    private(set) var localEthernet = LocalEthernet(up: false, megabitsPerSecond: nil, address: nil)
    private(set) var spark1 = SparkProbe(thermal: ThermalReading(), ports: [], pingMilliseconds: nil)
    private(set) var spark2 = SparkProbe(thermal: ThermalReading(), ports: [], pingMilliseconds: nil)
    private(set) var tenGigPing: Double?
    private(set) var updatedAt: Date?
    private(set) var error: String?
    private(set) var speedResults: [LinkKind: SpeedResult] = [:]
    private(set) var testing: LinkKind?
    private(set) var testError: [LinkKind: String] = [:]

    private var loop: Task<Void, Never>?

    init(enabled: Bool, onChange: @escaping () -> Void) {
        sshConfig = ("~/Library/Application Support/NVIDIA/Sync/config/ssh_config" as NSString).expandingTildeInPath
        self.enabled = enabled
        self.onChange = onChange
    }

    func start() {
        guard enabled, loop == nil else { return }
        loop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    var qsfpUp: Bool {
        Self.qsfpPorts.contains { name in
            (spark1.port(name)?.up ?? false) && (spark2.port(name)?.up ?? false)
        } && spark1.pingMilliseconds != nil
    }

    var tenGigUp: Bool {
        localEthernet.up && (spark1.port(Self.tenGigPort)?.up ?? false) && tenGigPing != nil
    }

    func testSpeed(_ kind: LinkKind) {
        guard testing == nil else { return }
        testing = kind
        testError[kind] = nil
        onChange()
        Task {
            let failure = await runTest(kind)
            testing = nil
            testError[kind] = failure
            onChange()
        }
    }

    // MARK: Poll

    func refresh() async {
        async let first = Self.probe(sshConfig: sshConfig, host: "joe-spark-1", ping: Self.qsfpTarget)
        async let second = Self.probe(sshConfig: sshConfig, host: "joe-spark-2", ping: nil)
        async let ethernet = Self.readLocalEthernet()
        async let ping = Self.ping(Self.sparkTenGigAddress)

        let (probe1, probe2, local, lanPing) = await (first, second, ethernet, ping)
        spark1 = probe1.probe
        spark2 = probe2.probe
        thermals[.a] = probe1.probe.thermal
        thermals[.b] = probe2.probe.thermal
        if let message = probe1.error ?? probe2.error {
            thermals[.a]?.error = probe1.error
            thermals[.b]?.error = probe2.error
            error = message
        } else {
            error = nil
        }
        localEthernet = local
        tenGigPing = lanPing
        updatedAt = Date()
        onChange()
    }

    // MARK: Speed tests

    private func runTest(_ kind: LinkKind) async -> String? {
        switch kind {
        case .tenGig:
            return await iperf(
                serverHost: "joe-spark-1",
                serverAddress: Self.sparkTenGigAddress,
                client: .local(Self.sparkTenGigAddress)
            )
        case .qsfp:
            return await iperf(
                serverHost: "joe-spark-2",
                serverAddress: Self.qsfpTarget,
                client: .remote(host: "joe-spark-1", address: Self.qsfpTarget)
            )
        }
    }

    private enum Client {
        case local(String)
        case remote(host: String, address: String)
    }

    private func iperf(serverHost: String, serverAddress: String, client: Client) async -> String? {
        let server = Task {
            await Self.ssh(
                sshConfig,
                serverHost,
                "iperf3 -s -1 -B \(serverAddress) -p 5201",
                timeout: .seconds(30)
            )
        }
        try? await Task.sleep(for: .seconds(1))
        let clientResult: ProcessResult
        switch client {
        case .local(let address):
            clientResult = await Self.run(
                "/opt/homebrew/bin/iperf3",
                ["-c", address, "-t", "10", "-p", "5201", "-J"],
                timeout: .seconds(25)
            )
        case .remote(let host, let address):
            clientResult = await Self.ssh(
                sshConfig,
                host,
                "iperf3 -c \(address) -t 10 -p 5201 -J",
                timeout: .seconds(25)
            )
        }
        _ = await server.value
        guard clientResult.succeeded, let data = clientResult.stdout.data(using: .utf8),
              let gbps = IperfParser.gigabitsPerSecond(data)
        else {
            let detail = (clientResult.stderr + clientResult.stdout).trimmed
            if detail.contains("iperf3") && detail.contains("not found") {
                return "iperf3 is not installed on the Spark. Run the setup command from the app folder."
            }
            if detail.isEmpty, !FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/iperf3"), case .local = client {
                return "iperf3 is not installed on this Mac. Install it with Homebrew."
            }
            return detail.isEmpty ? "The speed test failed." : detail
        }
        let kind: LinkKind = {
            if case .local = client { return .tenGig }
            return .qsfp
        }()
        speedResults[kind] = SpeedResult(gigabitsPerSecond: gbps, at: Date())
        return nil
    }

    // MARK: Commands

    private static let probeScript = """
    gpu=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d '[:space:]')
    echo "gpu_c=$gpu"
    ssd=; nic=; board=
    for h in /sys/class/hwmon/hwmon*; do
      name=$(cat "$h/name" 2>/dev/null || true)
      case "$name" in
        nvme) [ -z "$ssd" ] && ssd=$(cat "$h/temp1_input" 2>/dev/null || true) ;;
        mlx5) [ -z "$nic" ] && nic=$(cat "$h/temp1_input" 2>/dev/null || true) ;;
        acpitz)
          for f in "$h"/temp*_input; do
            v=$(cat "$f" 2>/dev/null || true)
            [ -n "$v" ] || continue
            if [ -z "$board" ] || [ "$v" -gt "$board" ]; then board=$v; fi
          done ;;
      esac
    done
    echo "ssd_mc=$ssd"
    echo "nic_mc=$nic"
    echo "board_mc=$board"
    for iface in enp1s0f0np0 enP2p1s0f0np0 enP7s7; do
      info=$(ethtool "$iface" 2>/dev/null)
      if printf '%s' "$info" | grep -q "Link detected: yes"; then state=up; else state=down; fi
      speed=$(printf '%s\\n' "$info" | awk -F': ' '/^[[:space:]]*Speed:/{print $2}' | tr -dc '0-9')
      echo "port $iface $state ${speed:-0}"
    done
    if [ -n "$1" ]; then
      ms=$(ping -c 1 -W 1 "$1" 2>/dev/null | awk -F'time=' '/time=/{print $2}' | awk '{print $1}')
      echo "ping_ms=$ms"
    fi
    """

    private static func probe(sshConfig: String, host: String, ping: String?) async -> (probe: SparkProbe, error: String?) {
        let command = "bash -s -- \(ping ?? "")"
        let result = await ssh(sshConfig, host, command, timeout: .seconds(20), input: Data(probeScript.utf8))
        if !result.succeeded && result.stdout.trimmed.isEmpty {
            let message = result.stderr.trimmed.isEmpty ? "Couldn't reach \(host)." : result.stderr.trimmed
            return (SparkProbe(thermal: ThermalReading(error: message), ports: [], pingMilliseconds: nil), message)
        }
        return (ProbeParser.parse(result.stdout), nil)
    }

    private static func readLocalEthernet() async -> LocalEthernet {
        let result = await run("/sbin/ifconfig", ["en0"], timeout: .seconds(5))
        return EthernetParser.parse(result.stdout)
    }

    private static func ping(_ address: String) async -> Double? {
        let result = await run("/sbin/ping", ["-c", "1", "-W", "1000", address], timeout: .seconds(3))
        guard let range = result.stdout.range(of: "time=") else { return nil }
        let rest = result.stdout[range.upperBound...]
        let number = rest.prefix { $0.isNumber || $0 == "." }
        return Double(number)
    }

    @discardableResult
    private static func ssh(
        _ config: String,
        _ host: String,
        _ command: String,
        timeout: Duration,
        input: Data? = nil
    ) async -> ProcessResult {
        await run("/usr/bin/ssh", [
            "-F", config,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            host,
            command,
        ], timeout: timeout, input: input)
    }

    private static func run(_ executable: String, _ arguments: [String], timeout: Duration, input: Data? = nil) async -> ProcessResult {
        (try? await ProcessRunner.run(executable, arguments, input: input, timeout: timeout))
            ?? ProcessResult(status: 1, stdout: "", stderr: "Couldn't run \(executable).", timedOut: false)
    }
}
