import Foundation
import Network
import Synchronization

public protocol PortProbe: Sendable {
    func isOpen(host: String, port: Int, timeout: Duration) async -> Bool
}

/// Checks whether a TCP port accepts connections. Used to see whether a Spark's sshd is up.
public struct TCPPortProbe: PortProbe {
    public init() {}

    public func isOpen(host: String, port: Int, timeout: Duration) async -> Bool {
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let done = Mutex(false)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18

        return await withCheckedContinuation { continuation in
            let finish: @Sendable (Bool) -> Void = { open in
                let first = done.withLock { finished in
                    defer { finished = true }
                    return !finished
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: open)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { finish(false) }
        }
    }
}
