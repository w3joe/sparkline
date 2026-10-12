import Foundation

public enum RemoteResult: Sendable, Equatable {
    case success(String)
    case failure(String)

    public var succeeded: Bool {
        if case .success = self { return true }
        return false
    }
}

public protocol RemoteShell: Sendable {
    /// Returns a problem description when SSH isn't ready for this Spark, or nil when it is.
    func preflight(_ config: SparkConfig) async -> String?
    /// Asks the Spark to power off. Success means the remote command exited with status 0.
    func requestShutdown(_ config: SparkConfig) async -> RemoteResult
    /// Verifies key, host key and sudo rule without shutting anything down.
    func checkAccess(_ config: SparkConfig) async -> RemoteResult
}

public struct ScannedHostKey: Sendable, Equatable {
    /// Raw `ssh-keyscan` lines, ready for a known_hosts file.
    public var knownHostsLines: String
    public var fingerprints: [String]
}

/// The app's own SSH key and known_hosts, kept apart from ~/.ssh.
public struct SSHEnvironment: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func standard() -> SSHEnvironment {
        SSHEnvironment(directory: URL.applicationSupportDirectory
            .appending(path: "GB10PowerMonitor", directoryHint: .isDirectory)
            .appending(path: "ssh", directoryHint: .isDirectory))
    }

    public var privateKey: URL { directory.appending(path: "id_ed25519") }
    public var publicKeyURL: URL { directory.appending(path: "id_ed25519.pub") }
    public var knownHosts: URL { directory.appending(path: "known_hosts") }

    public static func hostPattern(host: String, port: Int) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    public var hasKey: Bool { FileManager.default.fileExists(atPath: privateKey.path) }

    public func publicKey() -> String? {
        (try? String(contentsOf: publicKeyURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Creates the dedicated ed25519 key if it doesn't exist and returns its public half.
    @discardableResult
    public func ensureKey() async throws -> String {
        try prepareDirectory()
        if !hasKey {
            let result = try await ProcessRunner.run(
                "/usr/bin/ssh-keygen",
                ["-q", "-t", "ed25519", "-N", "", "-C", "gb10-power-monitor", "-f", privateKey.path]
            )
            guard result.succeeded else {
                throw SSHSetupError("ssh-keygen failed: \(result.stderr.trimmed)")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKey.path)
        guard let key = publicKey() else { throw SSHSetupError("The public key file is missing.") }
        return key
    }

    public func scanHostKey(host: String, port: Int) async throws -> ScannedHostKey {
        let scan = try await ProcessRunner.run(
            "/usr/bin/ssh-keyscan", ["-T", "5", "-t", "ed25519", "-p", String(port), host], timeout: .seconds(15)
        )
        let lines = scan.stdout
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
        guard !lines.isEmpty else {
            throw SSHSetupError("No ed25519 host key from \(host):\(port). Is the Spark on and reachable? \(scan.stderr.trimmed)")
        }
        let temp = FileManager.default.temporaryDirectory.appending(path: "gb10-keyscan-\(UUID().uuidString)")
        try (lines + "\n").write(to: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: temp) }
        let fingerprint = try await ProcessRunner.run("/usr/bin/ssh-keygen", ["-l", "-f", temp.path])
        let fingerprints = fingerprint.stdout.split(separator: "\n").map(String.init)
        return ScannedHostKey(knownHostsLines: lines, fingerprints: fingerprints)
    }

    /// Replaces any pinned key for this host with the scanned one.
    public func pin(_ scanned: ScannedHostKey, host: String, port: Int) async throws {
        try prepareDirectory()
        if FileManager.default.fileExists(atPath: knownHosts.path) {
            _ = try await ProcessRunner.run(
                "/usr/bin/ssh-keygen", ["-R", Self.hostPattern(host: host, port: port), "-f", knownHosts.path]
            )
            try? FileManager.default.removeItem(at: knownHosts.appendingPathExtension("old"))
        }
        let existing = (try? String(contentsOf: knownHosts, encoding: .utf8)) ?? ""
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + separator + scanned.knownHostsLines + "\n").write(to: knownHosts, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHosts.path)
    }

    public func isPinned(host: String, port: Int) async -> Bool {
        guard FileManager.default.fileExists(atPath: knownHosts.path) else { return false }
        let result = try? await ProcessRunner.run(
            "/usr/bin/ssh-keygen", ["-F", Self.hostPattern(host: host, port: port), "-f", knownHosts.path]
        )
        return result?.succeeded == true && !(result?.stdout.trimmed.isEmpty ?? true)
    }

    public func sshArguments(_ config: SparkConfig, command: String) -> [String] {
        [
            "-F", "/dev/null",
            "-n",
            "-i", privateKey.path,
            "-p", String(config.sshPort),
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "UserKnownHostsFile=\"\(knownHosts.path)\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "-o", "LogLevel=ERROR",
            "\(config.sshUser)@\(config.sshHost)",
            command,
        ]
    }
}

public struct SSHSetupError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Runs the two commands the Spark-side forced command accepts: `check` and `poweroff`.
public struct SSHShell: RemoteShell {
    public let environment: SSHEnvironment
    public let timeout: Duration

    public init(environment: SSHEnvironment, timeout: Duration = .seconds(30)) {
        self.environment = environment
        self.timeout = timeout
    }

    public func preflight(_ config: SparkConfig) async -> String? {
        guard config.hasSSH else { return "SSH host and user aren't set for \(config.name)." }
        guard environment.hasKey else { return "The SSH key hasn't been created yet. Finish SSH setup first." }
        guard await environment.isPinned(host: config.sshHost, port: config.sshPort) else {
            return "\(config.name)'s host key hasn't been verified yet. Finish SSH setup first."
        }
        return nil
    }

    public func requestShutdown(_ config: SparkConfig) async -> RemoteResult {
        await run(config, command: "poweroff")
    }

    public func checkAccess(_ config: SparkConfig) async -> RemoteResult {
        if let problem = await preflight(config) { return .failure(problem) }
        let result = await run(config, command: "check")
        if case .success(let output) = result, !output.contains("gb10-ok") {
            return .failure("Unexpected reply from \(config.name): \(output)")
        }
        return result
    }

    private func run(_ config: SparkConfig, command: String) async -> RemoteResult {
        do {
            let result = try await ProcessRunner.run(
                "/usr/bin/ssh", environment.sshArguments(config, command: command), timeout: timeout
            )
            if result.succeeded { return .success(result.stdout.trimmed) }
            return .failure(Self.describe(result))
        } catch {
            return .failure("Couldn't run ssh: \(error.localizedDescription)")
        }
    }

    static func describe(_ result: ProcessResult) -> String {
        let output = (result.stderr + "\n" + result.stdout).trimmed
        if result.timedOut { return "SSH didn't finish in time." }
        if output.contains("gb10-sudo-missing") {
            return "The sudo rule for systemctl poweroff is missing on the Spark."
        }
        if output.contains("Host key verification failed") || output.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            return "The Spark's host key doesn't match the pinned key. Verify it again in setup."
        }
        if output.contains("Permission denied") {
            return "The Spark rejected the app's SSH key. Check the authorized_keys line."
        }
        if output.contains("Connection refused") || output.contains("timed out") || output.contains("No route to host") {
            return "Couldn't connect over SSH: \(output)"
        }
        return output.isEmpty ? "ssh exited with status \(result.status)." : "ssh exited with status \(result.status): \(output)"
    }
}

/// The commands the user pastes into a terminal on the Spark.
public enum SparkSetupScript {
    public static let commandPath = "/usr/local/bin/gb10-power-command"

    public static let forcedCommand = """
        #!/bin/sh
        # GB10 Power Monitor: the only commands its SSH key may run.
        case "$SSH_ORIGINAL_COMMAND" in
          check)
            if sudo -n -l /usr/bin/systemctl poweroff >/dev/null 2>&1; then echo gb10-ok; else echo gb10-sudo-missing; exit 3; fi ;;
          poweroff)
            exec sudo -n /usr/bin/systemctl poweroff ;;
          *)
            echo gb10-unsupported; exit 2 ;;
        esac
        """

    public static func sudoersLine(user: String) -> String {
        "\(user) ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff"
    }

    public static func authorizedKeysLine(publicKey: String) -> String {
        "restrict,command=\"\(commandPath)\" \(publicKey)"
    }

    public static func render(user: String, publicKey: String) -> String {
        """
        sudo tee \(commandPath) >/dev/null <<'GB10EOF'
        \(forcedCommand)
        GB10EOF
        sudo chmod 755 \(commandPath)
        echo '\(sudoersLine(user: user))' | sudo tee /etc/sudoers.d/gb10-power >/dev/null
        sudo chmod 440 /etc/sudoers.d/gb10-power
        sudo visudo -cf /etc/sudoers.d/gb10-power
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        echo '\(authorizedKeysLine(publicKey: publicKey))' >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        """
    }

    public static let fingerprintCommand = "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"
}

extension String {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
