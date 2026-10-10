import Foundation
import XCTest
@testable import OlcRTCClientKit

final class LegacyRuntimeControllerTests: XCTestCase {
    private let options = OlcRTCStartOptions(profile: ConnectionProfile.empty)

    func testCancelledSessionNeverStarts() async {
        let fake = LegacyFakeAPI()
        let controller = LegacyRuntimeController(api: fake.api)
        let session = LegacyRuntimeController.Session()
        controller.requestStop(session)
        do {
            try await controller.start(session, options: options)
            XCTFail("Cancelled session started")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fake.counts.starts, 0)
    }

    func testOldStopCannotStopNewSession() async throws {
        let fake = LegacyFakeAPI()
        let controller = LegacyRuntimeController(api: fake.api)
        let old = LegacyRuntimeController.Session()
        try await controller.start(old, options: options)
        let stopped = await controller.stop(old)
        XCTAssertTrue(stopped)
        let next = LegacyRuntimeController.Session()
        try await controller.start(next, options: options)
        let staleStop = await controller.stop(old)
        XCTAssertTrue(staleStop)
        XCTAssertTrue(controller.isRunning(next))
        XCTAssertEqual(fake.counts.stops, 1)
        _ = await controller.stop(next)
    }

    func testTimeoutKeepsOwnershipAndConcurrentStopsJoinOneNativeStop() async throws {
        let fake = LegacyFakeAPI(blockStop: true)
        let controller = LegacyRuntimeController(api: fake.api)
        let session = LegacyRuntimeController.Session()
        try await controller.start(session, options: options)
        async let first = controller.stop(session, timeoutMillis: 30)
        async let second = controller.stop(session, timeoutMillis: 30)
        let results = await (first, second)
        XCTAssertFalse(results.0)
        XCTAssertFalse(results.1)
        XCTAssertTrue(controller.isRunning(session))
        XCTAssertEqual(controller.activePort(session), options.socksPort)
        do {
            try await controller.start(LegacyRuntimeController.Session(), options: options)
            XCTFail("A new session acquired a stopping singleton")
        } catch { }
        fake.releaseStop.signal()
        let completed = await controller.stop(session)
        XCTAssertTrue(completed)
        XCTAssertFalse(controller.isRunning(session))
        XCTAssertNil(controller.activePort(session))
        XCTAssertEqual(fake.counts.stops, 1)
    }

    func testStopDuringReadinessDoesNotWaitForFullStartupTimeout() async throws {
        let fake = LegacyFakeAPI()
        let controller = LegacyRuntimeController(api: fake.api)
        let session = LegacyRuntimeController.Session()
        try await controller.start(session, options: options)
        let waiter = Task { try await controller.waitReady(session, timeoutMillis: 60_000) }
        // The stop may win admission or interrupt the next readiness slice. Both
        // must finish without waiting for the full startup deadline.
        let completed = await controller.stop(session, timeoutMillis: 1_000)
        XCTAssertTrue(completed)
        do { try await waiter.value; XCTFail("Stopped session became ready") } catch { }
        XCTAssertEqual(fake.counts.stops, 1)
    }

    func testFailedStartCanBeCleanedUpBeforeRetry() async throws {
        let fake = LegacyFakeAPI(failStart: true)
        let controller = LegacyRuntimeController(api: fake.api)
        let session = LegacyRuntimeController.Session()
        do { try await controller.start(session, options: options); XCTFail("Expected failure") } catch { }
        let stopped = await controller.stop(session)
        XCTAssertTrue(stopped)
        XCTAssertNil(controller.activePort(session))
    }
}

private final class LegacyFakeAPI: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var running = false
    private let blockStop: Bool
    private let failStart: Bool
    let releaseStop = DispatchSemaphore(value: 0)

    init(blockStop: Bool = false, failStart: Bool = false) {
        self.blockStop = blockStop
        self.failStart = failStart
    }

    var counts: (starts: Int, stops: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (starts, stops)
    }

    var api: LegacyRuntimeController.API {
        .init(start: { [self] _ in
            lock.lock()
            defer { lock.unlock() }
            starts += 1
            if failStart { throw OlcRTCEngineError.invalidProfile("Test startup failure") }
            running = true
        }, waitReady: { _ in
            throw OlcRTCEngineError.invalidProfile("Test readiness pending")
        }, stop: { [self] in
            lock.lock()
            stops += 1
            lock.unlock()
            if blockStop { releaseStop.wait() }
            lock.lock()
            running = false
            lock.unlock()
        }, isRunning: { [self] in
            lock.lock()
            defer { lock.unlock() }
            return running
        })
    }
}
