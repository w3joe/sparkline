import Foundation
import PowerShared

/// Talks to the bundled Rust `tapo-helper` over newline-delimited JSON on its stdin/stdout.
/// The helper is started on first use and restarted after it exits; credentials are re-sent
/// to every new helper process.
public actor HelperClient: PlugClient {
    private let executable: URL
    private let arguments: [String]
    private let requestTimeout: Duration

    private var process: Process?
    private var input: FileHandle?
    private var generation = 0
    private var nextID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<Data, any Error>] = [:]
    private var credentials: TapoCredentials?

    public init(executable: URL, arguments: [String] = [], requestTimeout: Duration = .seconds(25)) {
        self.executable = executable
        self.arguments = arguments
        self.requestTimeout = requestTimeout
        // A write to a helper that just died must fail with EPIPE instead of killing the app.
        signal(SIGPIPE, SIG_IGN)
    }

    public static func bundled(simulate: Bool = false) -> HelperClient {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/tapo-helper")
        return HelperClient(executable: url, arguments: simulate ? ["--simulate"] : [])
    }

    // MARK: PlugClient

    public func configure(_ credentials: TapoCredentials) async throws {
        self.credentials = credentials
        let _: Empty = try await call(.configure(credentials))
    }

    public func read(_ spark: SparkID, ip: String) async throws -> PlugReading {
        try await call(.read(spark, ip))
    }

    public func set(_ spark: SparkID, ip: String, on: Bool) async throws -> PlugReading {
        try await call(.set(spark, ip, on))
    }

    public func info(_ spark: SparkID, ip: String) async throws -> PlugInfo {
        try await call(.info(spark, ip))
    }

    public func reset() async {
        let _: Empty? = try? await call(.reset)
    }

    public func ping() async throws {
        let _: Empty = try await call(.ping)
    }

    /// Only works when the helper runs with `--simulate`.
    public func simulatePower(_ spark: SparkID, milliwatts: Int?) async throws {
        let _: Empty = try await call(.simSetPower(spark, milliwatts))
    }

    public func stop() {
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
    }

    // MARK: Plumbing

    private struct Empty: Decodable, Sendable {}

    private struct Envelope: Decodable {
        var id: UInt64
    }

    private struct Response<R: Decodable>: Decodable {
        var ok: Bool
        var result: R?
        var error: PlugError?
    }

    private enum Op: Sendable {
        case configure(TapoCredentials)
        case read(SparkID, String)
        case set(SparkID, String, Bool)
        case info(SparkID, String)
        case reset
        case ping
        case simSetPower(SparkID, Int?)

        func json(id: UInt64) -> [String: Any] {
            var body: [String: Any] = ["id": id]
            switch self {
            case .configure(let c):
                body["op"] = "configure"; body["username"] = c.username; body["password"] = c.password
            case .read(let spark, let ip):
                body["op"] = "read"; body["plug"] = spark.rawValue; body["ip"] = ip
            case .set(let spark, let ip, let on):
                body["op"] = "set"; body["plug"] = spark.rawValue; body["ip"] = ip; body["on"] = on
            case .info(let spark, let ip):
                body["op"] = "info"; body["plug"] = spark.rawValue; body["ip"] = ip
            case .reset:
                body["op"] = "reset"
            case .ping:
                body["op"] = "ping"
            case .simSetPower(let spark, let mw):
                body["op"] = "sim_set_power"; body["plug"] = spark.rawValue; body["mw"] = mw ?? NSNull()
            }
            return body
        }
    }

    private func encode(_ op: Op, id: UInt64) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: op.json(id: id))
        data.append(0x0A)
        return data
    }

    private func ensureRunning() throws {
        if let process, process.isRunning, input != nil { return }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        generation += 1
        let generation = self.generation
        process.terminationHandler = { [weak self] _ in
            Task { await self?.helperExited(generation: generation) }
        }
        do {
            try process.run()
        } catch {
            throw PlugError(.helperUnavailable, "Couldn't start tapo-helper: \(error.localizedDescription)")
        }
        self.process = process
        self.input = stdin.fileHandleForWriting

        let reader = stdout.fileHandleForReading
        Task { [weak self] in
            do {
                for try await line in reader.bytes.lines {
                    await self?.receive(line)
                }
            } catch {}
            await self?.helperExited(generation: generation)
        }

        if let credentials {
            // Id 0 is never awaited; the helper applies configure before any later request.
            try? input?.write(contentsOf: encode(.configure(credentials), id: 0))
        }
    }

    private func receive(_ line: String) {
        let data = Data(line.utf8)
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let continuation = pending.removeValue(forKey: envelope.id)
        else { return }
        continuation.resume(returning: data)
    }

    private func helperExited(generation: Int) {
        guard generation == self.generation else { return }
        process = nil
        input = nil
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: PlugError(.helperUnavailable, "tapo-helper stopped unexpectedly"))
        }
    }

    private func timeOut(_ id: UInt64) {
        pending.removeValue(forKey: id)?.resume(
            throwing: PlugError(.timeout, "tapo-helper didn't answer in time")
        )
    }

    private func call<R: Decodable & Sendable>(_ op: Op) async throws -> R {
        try ensureRunning()
        let id = nextID
        nextID += 1
        let line = try encode(op, id: id)
        let timeout = requestTimeout

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input?.write(contentsOf: line)
            } catch {
                pending.removeValue(forKey: id)?.resume(
                    throwing: PlugError(.helperUnavailable, "Couldn't reach tapo-helper: \(error.localizedDescription)")
                )
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.timeOut(id)
            }
        }

        let response = try JSONDecoder().decode(Response<R>.self, from: data)
        if response.ok, let result = response.result {
            return result
        }
        throw response.error ?? PlugError(.protocolError, "tapo-helper sent an empty response")
    }
}
