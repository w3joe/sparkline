import Foundation

public struct ThermalReading: Equatable, Sendable {
    public var gpuC: Double?
    public var ssdC: Double?
    public var nicC: Double?
    public var boardC: Double?
    public var at: Date
    public var error: String?

    public init(gpuC: Double? = nil, ssdC: Double? = nil, nicC: Double? = nil, boardC: Double? = nil, at: Date = Date(), error: String? = nil) {
        self.gpuC = gpuC
        self.ssdC = ssdC
        self.nicC = nicC
        self.boardC = boardC
        self.at = at
        self.error = error
    }
}

public enum TemperatureBand: Equatable, Sendable {
    case normal, warm, hot

    public static func band(_ celsius: Double) -> TemperatureBand {
        if celsius >= 95 { return .hot }
        if celsius >= 85 { return .warm }
        return .normal
    }
}

public struct PortReading: Equatable, Sendable, Identifiable {
    public var name: String
    public var up: Bool
    public var megabitsPerSecond: Int?

    public var id: String { name }

    public init(name: String, up: Bool, megabitsPerSecond: Int?) {
        self.name = name
        self.up = up
        self.megabitsPerSecond = megabitsPerSecond
    }
}

public struct GPUProcess: Equatable, Sendable, Identifiable {
    public var pid: Int
    public var name: String
    public var command: String
    public var memoryMiB: Int?
    public var runningSeconds: Int?

    public var id: Int { pid }

    public init(pid: Int, name: String, command: String, memoryMiB: Int?, runningSeconds: Int?) {
        self.pid = pid
        self.name = name
        self.command = command
        self.memoryMiB = memoryMiB
        self.runningSeconds = runningSeconds
    }
}

public struct ContainerInfo: Equatable, Sendable, Identifiable {
    public var name: String
    public var image: String
    public var status: String

    public var id: String { name }

    public init(name: String, image: String, status: String) {
        self.name = name
        self.image = image
        self.status = status
    }
}

/// What a Spark is doing: GPU use, the processes holding the GPU, and running containers.
public struct Workload: Equatable, Sendable {
    public enum Activity: Equatable, Sendable {
        /// The GPU is doing real work.
        case busy
        /// Something holds the GPU or a container runs, but the GPU is quiet.
        case loaded
        case idle
    }

    public static let busyUtilization = 10

    public var gpuUtilization: Int?
    public var gpuWatts: Double?
    public var memoryUsedGB: Double?
    public var memoryTotalGB: Double?
    public var processes: [GPUProcess]
    public var containers: [ContainerInfo]

    public init(
        gpuUtilization: Int? = nil,
        gpuWatts: Double? = nil,
        memoryUsedGB: Double? = nil,
        memoryTotalGB: Double? = nil,
        processes: [GPUProcess] = [],
        containers: [ContainerInfo] = []
    ) {
        self.gpuUtilization = gpuUtilization
        self.gpuWatts = gpuWatts
        self.memoryUsedGB = memoryUsedGB
        self.memoryTotalGB = memoryTotalGB
        self.processes = processes
        self.containers = containers
    }

    public var activity: Activity {
        if (gpuUtilization ?? 0) >= Self.busyUtilization { return .busy }
        if !processes.isEmpty || !containers.isEmpty { return .loaded }
        return .idle
    }

    public var runningCount: Int { processes.count + containers.count }
}

/// One SSH probe of a Spark: temperatures, work, the ports we care about, and an optional ping.
public struct SparkProbe: Equatable, Sendable {
    public var thermal: ThermalReading
    public var workload: Workload
    public var ports: [PortReading]
    public var pingMilliseconds: Double?

    public init(thermal: ThermalReading, workload: Workload = Workload(), ports: [PortReading], pingMilliseconds: Double?) {
        self.thermal = thermal
        self.workload = workload
        self.ports = ports
        self.pingMilliseconds = pingMilliseconds
    }

    public var reachable: Bool { thermal.error == nil }

    public func port(_ name: String) -> PortReading? {
        ports.first { $0.name == name }
    }
}

public enum ProbeParser {
    /// Parses the key lines printed by the health probe script.
    public static func parse(_ text: String, at date: Date = Date()) -> SparkProbe {
        var values: [String: String] = [:]
        var ports: [PortReading] = []
        var processes: [GPUProcess] = []
        var containers: [ContainerInfo] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let fields = raw.split(separator: "\t", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if fields.first == "app" {
                guard fields.count >= 5, let pid = Int(fields[1]), !fields[4].isEmpty else { continue }
                processes.append(GPUProcess(
                    pid: pid,
                    name: fields[4],
                    command: fields.count > 5 && !fields[5].isEmpty ? fields[5] : fields[4],
                    memoryMiB: Int(fields[2]),
                    runningSeconds: Int(fields[3])
                ))
                continue
            }
            if fields.first == "ctr" {
                guard fields.count >= 4, !fields[1].isEmpty else { continue }
                containers.append(ContainerInfo(name: fields[1], image: fields[2], status: fields[3]))
                continue
            }
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("port ") {
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count >= 3 else { continue }
                let speed = Int(parts.count > 3 ? parts[3] : "")
                ports.append(PortReading(
                    name: parts[1],
                    up: parts[2] == "up",
                    megabitsPerSecond: (speed ?? 0) > 0 ? speed : nil
                ))
            } else if let split = line.firstIndex(of: "=") {
                let key = String(line[..<split])
                let value = String(line[line.index(after: split)...])
                values[key] = value
            }
        }
        let thermal = ThermalReading(
            gpuC: double(values["gpu_c"]),
            ssdC: milli(values["ssd_mc"]),
            nicC: milli(values["nic_mc"]),
            boardC: milli(values["board_mc"]),
            at: date
        )
        let totalKB = double(values["mem_total_kb"])
        let availableKB = double(values["mem_avail_kb"])
        let workload = Workload(
            gpuUtilization: double(values["gpu_util"]).map { Int($0.rounded()) },
            gpuWatts: double(values["gpu_w"]),
            memoryUsedGB: totalKB.flatMap { total in availableKB.map { (total - $0) / 1_048_576 } },
            memoryTotalGB: totalKB.map { $0 / 1_048_576 },
            processes: processes,
            containers: containers
        )
        return SparkProbe(thermal: thermal, workload: workload, ports: ports, pingMilliseconds: double(values["ping_ms"]))
    }

    private static func double(_ text: String?) -> Double? {
        guard let text, !text.isEmpty else { return nil }
        return Double(text)
    }

    private static func milli(_ text: String?) -> Double? {
        guard let value = double(text) else { return nil }
        return value / 1000
    }
}

public struct LocalEthernet: Equatable, Sendable {
    public var up: Bool
    public var megabitsPerSecond: Int?
    public var address: String?

    public init(up: Bool, megabitsPerSecond: Int?, address: String?) {
        self.up = up
        self.megabitsPerSecond = megabitsPerSecond
        self.address = address
    }
}

public enum EthernetParser {
    public static func parse(_ ifconfig: String) -> LocalEthernet {
        var up = false
        var megabits: Int?
        var address: String?
        for raw in ifconfig.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("status:") {
                up = line.contains("active")
            } else if line.hasPrefix("media:") {
                megabits = speed(in: line)
            } else if line.hasPrefix("inet "), address == nil {
                let parts = line.split(separator: " ")
                if parts.count > 1, parts[1] != "127.0.0.1" {
                    address = String(parts[1])
                }
            }
        }
        return LocalEthernet(up: up, megabitsPerSecond: megabits, address: address)
    }

    private static func speed(in media: String) -> Int? {
        let known = ["10Gbase-T": 10_000, "1000baseT": 1_000, "100baseTX": 100, "10baseT/UTP": 10]
        for (name, mbps) in known where media.contains(name) {
            return mbps
        }
        return nil
    }
}

public enum IperfParser {
    /// Gigabits per second from an `iperf3 -J` document. Prefers what the receiver measured.
    public static func gigabitsPerSecond(_ data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let end = root["end"] as? [String: Any]
        else { return nil }
        for key in ["sum_received", "sum_sent", "sum"] {
            if let sum = end[key] as? [String: Any], let bps = sum["bits_per_second"] as? Double, bps > 0 {
                return bps / 1_000_000_000
            }
        }
        return nil
    }
}

public enum LinkKind: String, Equatable, Sendable, CaseIterable, Identifiable {
    case tenGig
    case qsfp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tenGig: "Mac Studio to Spark 1"
        case .qsfp: "Spark 1 to Spark 2"
        }
    }

    public var detail: String {
        switch self {
        case .tenGig: "10G Ethernet"
        case .qsfp: "QSFP"
        }
    }
}

public struct SpeedResult: Equatable, Sendable {
    public var gigabitsPerSecond: Double
    public var at: Date

    public init(gigabitsPerSecond: Double, at: Date) {
        self.gigabitsPerSecond = gigabitsPerSecond
        self.at = at
    }
}

public enum HealthFormat {
    public static func celsius(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.0f°", value)
    }

    public static func megabits(_ value: Int?) -> String {
        guard let value else { return "–" }
        if value >= 1000, value % 1000 == 0 { return "\(value / 1000) Gb/s" }
        return "\(value) Mb/s"
    }

    public static func ping(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "–" }
        return milliseconds < 1 ? String(format: "%.2f ms", milliseconds) : String(format: "%.1f ms", milliseconds)
    }

    public static func gigabits(_ value: Double) -> String {
        value >= 1 ? String(format: "%.1f Gb/s", value) : String(format: "%.0f Mb/s", value * 1000)
    }

    public static func percent(_ value: Int?) -> String {
        guard let value else { return "–" }
        return "\(value)%"
    }

    public static func gigabytes(_ used: Double?, of total: Double?) -> String {
        switch (used, total) {
        case let (used?, total?): return String(format: "%.0f / %.0f GB", used, total)
        case let (used?, nil): return String(format: "%.0f GB", used)
        default: return "–"
        }
    }

    public static func memory(mebibytes: Int?) -> String {
        guard let mebibytes else { return "–" }
        return mebibytes >= 1024 ? String(format: "%.1f GB", Double(mebibytes) / 1024) : "\(mebibytes) MB"
    }

    public static func duration(seconds: Int?) -> String {
        guard let seconds else { return "–" }
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }
}
