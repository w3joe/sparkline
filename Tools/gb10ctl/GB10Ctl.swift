import Foundation
import PowerShared

/// Command-line access to the running app through the same App Group path the widgets use.
@main
struct GB10Ctl {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let container = SharedContainer.appGroup() else {
            fail("The App Group container isn't available. Is gb10ctl signed with the app group entitlement?")
        }

        switch args.first {
        case "status":
            guard let snapshot = WidgetSnapshot.load(from: container) else { fail("No snapshot yet. Is the app running?") }
            let age = Int(Date().timeIntervalSince(snapshot.generatedAt))
            print("snapshot \(age)s old, monitoring \(snapshot.monitoring ? "on" : "off")")
            for spark in snapshot.sparks {
                let watts = spark.watts.map { String(format: "%.1f W", $0) } ?? "– W"
                let reading = spark.readingAt.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "never"
                let extra = [spark.operation, spark.error].compactMap { $0 }.joined(separator: "; ")
                print("\(spark.id.rawValue) \(spark.name): \(spark.outlet.rawValue) \(spark.computer.rawValue) \(watts) (reading \(reading))\(extra.isEmpty ? "" : " – \(extra)")")
            }
            if let notice = snapshot.notice {
                print("notice: \(notice.success ? "ok" : "failed") \(notice.message)")
            }

        case "on", "shutdown":
            guard args.count == 2, let spark = SparkID(rawValue: args[1]) else { usage() }
            let action: PowerAction = args[0] == "on" ? .on : .shutDown
            do {
                let ack = try await CommandBus(container: container).send(spark: spark, action: action)
                print("accepted: \(ack.message)")
            } catch {
                fail(error.localizedDescription)
            }

        default:
            usage()
        }
    }

    static func usage() -> Never {
        fail("usage: gb10ctl status | on <a|b> | shutdown <a|b>")
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
