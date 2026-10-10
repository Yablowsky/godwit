import XCTest
@testable import OlcRTCClientKit

final class OlcRTCConfigYAMLBuilderTests: XCTestCase {
    func testVideoConfigDoesNotEmitRemovedCoreOptions() {
        let profile = ConnectionProfile(name: "Video", transport: .videochannel)
        let yaml = OlcRTCConfigYAMLBuilder(options: OlcRTCStartOptions(profile: profile), socksPort: profile.socksPort).yaml()
        XCTAssertFalse(yaml.contains("bitrate:"))
        XCTAssertFalse(yaml.contains("hw:"))
        XCTAssertTrue(yaml.contains("video:"))
    }

    private let key = "258aa76a14d8e5d22a9eeb57190e454d4062c5185ec4b5f9a3631de76f3001a2"

    func testBuildsDocumentedJitsiDatachannelClientConfig() {
        let profile = ConnectionProfile(
            name: "Jitsi CH",
            carrier: .jitsi,
            transport: .datachannel,
            roomID: "https://meet.cryptopro.ru/pasklove-olcrtc-548f323503997581",
            clientID: "legacy-client-must-not-be-written",
            keyHex: key,
            socksPort: ConnectionProfile.defaultSocksPort,
            socksUser: "",
            socksPass: "",
            dnsServer: "8.8.8.8:53"
        )

        let yaml = OlcRTCConfigYAMLBuilder(
            options: OlcRTCStartOptions(profile: profile),
            socksPort: profile.socksPort
        ).yaml()

        XCTAssertEqual(
            yaml,
            """
            mode: cnc
            auth:
              provider: "jitsi"
            room:
              id: "https://meet.cryptopro.ru/pasklove-olcrtc-548f323503997581"
            crypto:
              key: "258aa76a14d8e5d22a9eeb57190e454d4062c5185ec4b5f9a3631de76f3001a2"
            net:
              transport: "datachannel"
              dns: "8.8.8.8:53"
            socks:
              host: "127.0.0.1"
              port: 21080
            debug: false

            """
        )
        XCTAssertFalse(yaml.contains("legacy-client"))
        XCTAssertFalse(yaml.contains("data:"))
        XCTAssertFalse(yaml.contains("vp8:"))
        XCTAssertFalse(yaml.contains("sei:"))
        XCTAssertFalse(yaml.contains("video:"))
    }

    func testBuildsOnlySelectedTransportTuning() {
        let profile = ConnectionProfile(
            name: "WB",
            carrier: .wbstream,
            transport: .vp8channel,
            roomID: "room-01",
            keyHex: key,
            vp8FPS: 60,
            vp8BatchSize: 64
        )

        let yaml = OlcRTCConfigYAMLBuilder(
            options: OlcRTCStartOptions(profile: profile),
            socksPort: profile.socksPort
        ).yaml()

        XCTAssertTrue(yaml.contains("vp8:\n  fps: 60\n  batch_size: 64\n"))
        XCTAssertFalse(yaml.contains("sei:"))
        XCTAssertFalse(yaml.contains("video:"))
    }
}
