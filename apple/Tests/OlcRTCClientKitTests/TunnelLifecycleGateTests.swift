import XCTest
@testable import OlcRTCClientKit

final class TunnelLifecycleGateTests: XCTestCase {
    func testStopBeforeScheduledStartupInvalidatesAdmission() throws {
        let gate = TunnelLifecycleGate()
        let token = try gate.begin()
        XCTAssertEqual(gate.cancelCurrent(), token)
        XCTAssertFalse(gate.isActive(token))
    }

    func testRepeatedStartIsRejectedUntilCleanupFinishes() throws {
        let gate = TunnelLifecycleGate()
        let token = try gate.begin()
        XCTAssertThrowsError(try gate.begin())
        gate.cancel(token)
        XCTAssertThrowsError(try gate.begin())
        gate.finish(token)
        XCTAssertNoThrow(try gate.begin())
    }

    func testOldCompletionCannotReleaseNewSession() throws {
        let gate = TunnelLifecycleGate()
        let old = try gate.begin()
        gate.finish(old)
        let current = try gate.begin()
        gate.finish(old)
        gate.cancel(old)
        XCTAssertTrue(gate.isActive(current))
        XCTAssertThrowsError(try gate.begin())
    }

    func testStopWithoutSessionDoesNotCancelFutureStart() throws {
        let gate = TunnelLifecycleGate()
        XCTAssertNil(gate.cancelCurrent())
        let token = try gate.begin()
        XCTAssertTrue(gate.isActive(token))
    }
}
