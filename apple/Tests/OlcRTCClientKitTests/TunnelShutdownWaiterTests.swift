import XCTest
@testable import OlcRTCClientKit

@MainActor
final class TunnelShutdownWaiterTests: XCTestCase {
    func testAlreadyDisconnectedReturnsImmediately() async throws {
        try await TunnelShutdownWaiter.wait(timeout: .zero) { true }
    }

    func testDoesNotFinishUntilDisconnectionIsConfirmed() async throws {
        var disconnected = false
        var checks = 0
        var finished = false
        let task = Task {
            try await TunnelShutdownWaiter.wait(timeout: .seconds(2), pollInterval: .milliseconds(1)) {
                checks += 1
                return disconnected
            }
            finished = true
        }
        while checks == 0 { await Task.yield() }
        XCTAssertFalse(finished)
        disconnected = true
        try await task.value
        XCTAssertTrue(finished)
    }

    func testTimeoutDoesNotPretendToBeDisconnected() async {
        do {
            try await TunnelShutdownWaiter.wait(timeout: .zero) { false }
            XCTFail("Expected a shutdown timeout")
        } catch is TunnelShutdownError {
            // Expected: caller keeps ownership of the still-disconnecting tunnel.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancelledWaitThrowsCancellation() async {
        let task = Task {
            try await TunnelShutdownWaiter.wait { false }
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
