import Foundation
import XCTest
@testable import OlcRTCClientKit

final class ConnectionProfileTests: XCTestCase {
    func testNewProfilesUseLegacyTransportDefaults() {
        let profile = ConnectionProfile.empty
        XCTAssertEqual(profile.vp8FPS, 60)
        XCTAssertEqual(profile.seiFPS, 60)
        XCTAssertEqual(profile.videoFPS, 60)
    }

    func testLegacyProfilesKeepTheirOldFPSDefaults() throws {
        let data = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"Legacy\"}".utf8)
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        XCTAssertEqual(profile.vp8FPS, 60)
        XCTAssertEqual(profile.seiFPS, 60)
        XCTAssertEqual(profile.videoFPS, 60)
    }

    func testExistingCustomFPSIsNotMigrated() throws {
        let original = ConnectionProfile(name: "Custom", vp8FPS: 24, seiFPS: 25, videoFPS: 20)
        let restored = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.normalizedForCurrentDefaults().vp8FPS, 24)
        XCTAssertEqual(restored.seiFPS, 25)
        XCTAssertEqual(restored.videoFPS, 20)
    }

    func testEmptyProfileUsesDefaultSocksPort() {
        XCTAssertEqual(ConnectionProfile.empty.socksPort, 21_080)
        XCTAssertEqual(ConnectionProfile.empty.socksPort, ConnectionProfile.defaultSocksPort)
    }

    func testDecodingMissingSocksPortUsesDefaultSocksPort() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "name": "Legacy"
            }
            """.utf8
        )

        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        XCTAssertEqual(profile.socksPort, ConnectionProfile.defaultSocksPort)
    }

    func testDecodingReservedSocksPortUsesDefaultSocksPort() throws {
        let id = UUID()
        let data = Data(
            """
            {
              "id": "\(id.uuidString)",
              "name": "Legacy",
              "socksPort": 65
            }
            """.utf8
        )

        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)

        XCTAssertEqual(profile.socksPort, ConnectionProfile.defaultSocksPort)
    }

    func testKeepsCustomUserSpaceSocksPort() {
        let profile = ConnectionProfile(name: "Custom", socksPort: 21_081)

        XCTAssertEqual(profile.socksPort, 21_081)
    }
}
