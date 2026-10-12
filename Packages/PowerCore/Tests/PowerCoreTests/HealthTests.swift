import Foundation
import Testing
@testable import PowerCore

@Suite("Health probes")
struct HealthTests {
    @Test func parsesTemperaturesPortsAndPing() {
        let text = """
        gpu_c=46
        ssd_mc=49850
        nic_mc=51000
        board_mc=51800
        port enp1s0f0np0 up 200000
        port enP2p1s0f0np0 up 200000
        port enP7s7 down 0
        ping_ms=0.195
        """
        let probe = ProbeParser.parse(text)
        #expect(probe.thermal.gpuC == 46)
        #expect(probe.thermal.ssdC == 49.85)
        #expect(probe.thermal.nicC == 51)
        #expect(probe.thermal.boardC == 51.8)
        #expect(probe.port("enp1s0f0np0") == PortReading(name: "enp1s0f0np0", up: true, megabitsPerSecond: 200_000))
        #expect(probe.port("enP7s7")?.up == false)
        #expect(probe.port("enP7s7")?.megabitsPerSecond == nil)
        #expect(probe.pingMilliseconds == 0.195)
    }

    @Test func temperatureBands() {
        #expect(TemperatureBand.band(46) == .normal)
        #expect(TemperatureBand.band(85) == .warm)
        #expect(TemperatureBand.band(95) == .hot)
    }

    @Test func parsesLocalTenGigEthernet() {
        let text = """
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        	inet 192.168.49.1 netmask 0xfffffffc broadcast 192.168.49.3
        	media: autoselect (10Gbase-T <full-duplex,flow-control>)
        	status: active
        """
        let ethernet = EthernetParser.parse(text)
        #expect(ethernet.up)
        #expect(ethernet.megabitsPerSecond == 10_000)
        #expect(ethernet.address == "192.168.49.1")
    }

    @Test func parsesIperfReceiverRate() throws {
        let json = """
        {"end":{"sum_sent":{"bits_per_second":9000000000},"sum_received":{"bits_per_second":9410000000}}}
        """.data(using: .utf8)!
        let gbps = try #require(IperfParser.gigabitsPerSecond(json))
        #expect(abs(gbps - 9.41) < 0.001)
    }
}
