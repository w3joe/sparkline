import Foundation
import Testing
@testable import PowerCore
import PowerShared

private let helperPath = ProcessInfo.processInfo.environment["TAPO_HELPER_PATH"]

@Suite("tapo-helper bridge", .enabled(if: helperPath != nil, "Set TAPO_HELPER_PATH (make test-core does)"))
struct HelperClientTests {
    func client() -> HelperClient {
        HelperClient(executable: URL(fileURLWithPath: helperPath!), arguments: ["--simulate"], requestTimeout: .seconds(5))
    }

    @Test func readsAndSwitchesPlugsIndependently() async throws {
        let client = client()
        try await client.configure(TapoCredentials(username: "joe@example.com", password: "secret"))
        let off = try await client.set(.a, ip: "10.0.0.2", on: false)
        let b = try await client.read(.b, ip: "10.0.0.3")
        #expect(!off.deviceOn)
        #expect(off.powerMilliwatts == 0)
        #expect(b.deviceOn)
        #expect(b.watts > 0)
        await client.stop()
    }

    @Test func reportsUnreachableAndBadCredentials() async throws {
        let client = client()
        try await client.configure(TapoCredentials(username: "joe@example.com", password: "secret"))
        await #expect(throws: PlugError.self) { try await client.read(.a, ip: "unreachable") }
        do {
            _ = try await client.read(.a, ip: "unreachable")
        } catch let error as PlugError {
            #expect(error.kind == .unreachable)
        }
        // The other plug still works.
        #expect(try await client.read(.b, ip: "10.0.0.3").deviceOn)

        try await client.configure(TapoCredentials(username: "joe@example.com", password: "wrong"))
        do {
            _ = try await client.read(.a, ip: "10.0.0.2")
            Issue.record("expected auth failure")
        } catch let error as PlugError {
            #expect(error.kind == .authFailed)
        }
        await client.stop()
    }

    @Test func restartsTheHelperAndResendsCredentials() async throws {
        let client = client()
        try await client.configure(TapoCredentials(username: "joe@example.com", password: "secret"))
        await client.stop()
        let reading = try await client.read(.a, ip: "10.0.0.2")
        #expect(reading.deviceOn)
        await client.stop()
    }

    @Test func missingExecutableIsReported() async {
        let client = HelperClient(executable: URL(fileURLWithPath: "/nonexistent/tapo-helper"))
        do {
            try await client.ping()
            Issue.record("expected failure")
        } catch let error as PlugError {
            #expect(error.kind == .helperUnavailable)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

@Suite("SSH setup")
struct SSHTests {
    @Test func setupScriptRestrictsTheKey() {
        let script = SparkSetupScript.render(user: "joe", publicKey: "ssh-ed25519 AAAAC3Nza gb10-power-monitor")
        #expect(script.contains("joe ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff"))
        #expect(script.contains("restrict,command=\"/usr/local/bin/gb10-power-command\" ssh-ed25519 AAAAC3Nza gb10-power-monitor"))
        #expect(script.contains("visudo -cf"))
        #expect(script.contains("poweroff)\n    exec sudo -n /usr/bin/systemctl poweroff"))
    }

    @Test func hostPatternsFollowKnownHostsFormat() {
        #expect(SSHEnvironment.hostPattern(host: "spark-a.local", port: 22) == "spark-a.local")
        #expect(SSHEnvironment.hostPattern(host: "10.0.0.5", port: 2222) == "[10.0.0.5]:2222")
    }

    @Test func sshArgumentsAreStrict() {
        let env = SSHEnvironment(directory: URL(fileURLWithPath: "/tmp/gb10"))
        let args = env.sshArguments(testSpark(), command: "poweroff")
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("StrictHostKeyChecking=yes"))
        #expect(args.contains("UserKnownHostsFile=/tmp/gb10/known_hosts"))
        #expect(args.suffix(2) == ["joe@spark-a.local", "poweroff"])
    }

    @Test func errorsAreExplained() {
        func describe(_ stderr: String, stdout: String = "", status: Int32 = 255) -> String {
            SSHShell.describe(ProcessResult(status: status, stdout: stdout, stderr: stderr, timedOut: false))
        }
        #expect(describe("joe@spark: Permission denied (publickey).").contains("rejected the app's SSH key"))
        #expect(describe("Host key verification failed.").contains("host key"))
        #expect(describe("", stdout: "gb10-sudo-missing", status: 3).contains("sudo rule"))
    }

    @Test func generatesAPrivateKeyWithStrictPermissions() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gb10-ssh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = SSHEnvironment(directory: dir)
        let key = try await env.ensureKey()
        #expect(key.hasPrefix("ssh-ed25519 "))
        let perms = try FileManager.default.attributesOfItem(atPath: env.privateKey.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        // A second call reuses the same key.
        #expect(try await env.ensureKey() == key)
        #expect(await !env.isPinned(host: "spark-a.local", port: 22))
    }

    @Test func pinningIsReplacedNotDuplicated() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "gb10-ssh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = SSHEnvironment(directory: dir)
        let pub = try await env.ensureKey()
        let keyBody = pub.split(separator: " ").prefix(2).joined(separator: " ")
        let scanned = ScannedHostKey(knownHostsLines: "spark-a.local \(keyBody)", fingerprints: [])
        try await env.pin(scanned, host: "spark-a.local", port: 22)
        try await env.pin(scanned, host: "spark-a.local", port: 22)
        #expect(await env.isPinned(host: "spark-a.local", port: 22))
        let lines = try String(contentsOf: env.knownHosts, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 1)
    }
}
