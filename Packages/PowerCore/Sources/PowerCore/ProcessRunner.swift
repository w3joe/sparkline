import Foundation
import Synchronization

public struct ProcessResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

public enum ProcessRunner {
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// Runs an executable to completion, killing it if it outlives `timeout`.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        input: Data? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> ProcessResult {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Box(Process())
                process.value.executableURL = URL(fileURLWithPath: executable)
                process.value.arguments = arguments
                let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
                process.value.standardInput = stdin
                process.value.standardOutput = stdout
                process.value.standardError = stderr

                do {
                    try process.value.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let timedOut = Mutex(false)
                let killer = DispatchWorkItem {
                    if process.value.isRunning {
                        timedOut.withLock { $0 = true }
                        process.value.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: killer)

                if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
                try? stdin.fileHandleForWriting.close()

                let out = Box(Data())
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    out.value = stdout.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let err = stderr.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.value.waitUntilExit()
                killer.cancel()

                continuation.resume(returning: ProcessResult(
                    status: process.value.terminationStatus,
                    stdout: String(decoding: out.value, as: UTF8.self),
                    stderr: String(decoding: err, as: UTF8.self),
                    timedOut: timedOut.withLock { $0 }
                ))
            }
        }
    }
}
