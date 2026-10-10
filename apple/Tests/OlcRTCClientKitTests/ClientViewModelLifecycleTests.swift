#if os(macOS)
import Foundation
import XCTest
@testable import OlcRTCClientKit

@MainActor
final class ClientViewModelLifecycleTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "GodwitLifecycleTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testRepeatedStartDoesNotLaunchAnotherEngine() async throws {
        let engine = ControlledEngine(holdStart: true)
        let model = makeModel(engine)
        model.start()
        model.start()
        try await eventually { await engine.startCount == 1 }
        let starts = await engine.startCount
        XCTAssertEqual(starts, 1)
        model.stop()
        await engine.releaseStart()
        try await eventually { model.status == .stopped }
    }

    func testStopJoinsLateStartupBeforeAllowingRestart() async throws {
        let engine = ControlledEngine(holdStart: true)
        let model = makeModel(engine)
        model.start()
        try await eventually { await engine.startIsSuspended }
        model.stop()
        try await eventually { await engine.stopCount > 0 }
        XCTAssertEqual(model.status, .stopping)
        XCTAssertFalse(model.canStart)
        model.start()
        await engine.releaseStart() // Simulate a native start that returns after cancellation.
        try await eventually { model.status == .stopped }
        let starts = await engine.startCount
        let readyCalls = await engine.readyCount
        let running = await engine.isRunning
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(readyCalls, 0)
        XCTAssertFalse(running)
        XCTAssertTrue(model.canStart)
    }

    func testLateReadyDoesNotResurrectStoppedConnection() async throws {
        let engine = ControlledEngine(holdReady: true)
        let model = makeModel(engine)
        model.start()
        try await eventually { await engine.readyIsSuspended }
        model.stop()
        await engine.releaseReady()
        try await eventually { model.status == .stopped }
        XCTAssertFalse(model.logs.contains { $0.contains("SOCKS proxy is ready") })
        XCTAssertTrue(model.canStart)
    }

    func testStopTimeoutKeepsOwnershipAndAllowsStopRetry() async throws {
        let engine = ControlledEngine()
        await engine.setRefuseStop(true)
        let model = makeModel(engine)
        model.start()
        try await eventually { model.status == .ready }
        model.stop()
        try await eventually { !model.isStopInProgress }
        XCTAssertEqual(model.status, .stopping)
        XCTAssertFalse(model.canStart)
        XCTAssertTrue(model.canStop)
        await engine.setRefuseStop(false)
        model.stop()
        try await eventually { model.status == .stopped }
        XCTAssertTrue(model.canStart)
    }

    func testEventStreamDoesNotRetainViewModel() async throws {
        let engine = ControlledEngine()
        var model: ClientViewModel? = makeModel(engine)
        let weakModel = WeakReference(model!)
        model = nil
        try await eventually { weakModel.value == nil }
    }

    private func makeModel(_ engine: ControlledEngine) -> ClientViewModel {
        let store = ProfileStore(defaults: defaults)
        store.saveUseSystemProxy(false) // Never mutate the test machine's proxy settings.
        let model = ClientViewModel(engine: engine, store: store)
        let profile = ConnectionProfile(
            name: "Lifecycle test", carrier: .jitsi, transport: .datachannel,
            roomID: "https://example.invalid/test", keyHex: String(repeating: "ab", count: 32)
        )
        // The lifecycle fixture is intentionally not persisted, so it never touches Keychain.
        model.draft = profile
        model.selectedProfileID = profile.id
        return model
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Lifecycle condition did not become true")
                throw TestTimeout()
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private struct TestTimeout: Error {}

    private final class WeakReference<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }
}

private actor ControlledEngine: OlcRTCEngine {
    nonisolated let events = AsyncStream<String> { _ in }
    private(set) var startCount = 0
    private(set) var readyCount = 0
    private(set) var stopCount = 0
    private var running = false
    private let holdStart: Bool
    private let holdReady: Bool
    private var refuseStop = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Never>?

    init(holdStart: Bool = false, holdReady: Bool = false) {
        self.holdStart = holdStart
        self.holdReady = holdReady
    }

    var isRunning: Bool { get async { running } }
    var activeSocksPort: Int? { get async { running ? 21_080 : nil } }
    var startIsSuspended: Bool { startContinuation != nil }
    var readyIsSuspended: Bool { readyContinuation != nil }

    func start(options: OlcRTCStartOptions) async throws {
        startCount += 1
        if holdStart {
            await withCheckedContinuation { startContinuation = $0 }
        }
        running = true
    }

    func waitReady(timeoutMillis: Int) async throws {
        readyCount += 1
        if holdReady {
            await withCheckedContinuation { readyContinuation = $0 }
        }
    }

    func stop() async {
        stopCount += 1
        if !refuseStop { running = false }
    }

    func releaseStart() { startContinuation?.resume(); startContinuation = nil }
    func releaseReady() { readyContinuation?.resume(); readyContinuation = nil }
    func setRefuseStop(_ value: Bool) { refuseStop = value }
}
#endif
