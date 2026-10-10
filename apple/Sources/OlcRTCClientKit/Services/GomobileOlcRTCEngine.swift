import Foundation

#if canImport(Mobile)
@preconcurrency import Mobile
#endif

public final class GomobileOlcRTCEngine: OlcRTCEngine, @unchecked Sendable {
    private let eventPair = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(300))
    private let lock = NSLock()
    private var session: LegacyRuntimeController.Session?

    #if canImport(Mobile)
    private static let controller = LegacyRuntimeController(api: .init(
        start: { options in
            try LegacyMobileConfiguration.apply(options)
            var error: NSError?
            guard MobileStart(options.carrierName, options.roomID, options.clientID,
                              options.keyHex, options.socksPort, options.socksUser,
                              options.socksPass, &error) else {
                throw error ?? OlcRTCEngineError.invalidProfile("Legacy core failed to start.")
            }
        },
        waitReady: { timeout in
            var error: NSError?
            guard MobileWaitReady(timeout, &error) else {
                throw error ?? OlcRTCEngineError.invalidProfile("Legacy core is not ready.")
            }
        },
        stop: { MobileStop() },
        isRunning: { MobileIsRunning() }
    ))
    #endif

    public init() {}

    deinit {
        eventPair.continuation.finish()
        #if canImport(Mobile)
        if let session { Self.controller.requestStop(session) }
        #endif
    }

    public var events: AsyncStream<String> { eventPair.stream }

    public var isRunning: Bool {
        get async {
            #if canImport(Mobile)
            return withLock { session.map { Self.controller.isRunning($0) } ?? false }
            #else
            return false
            #endif
        }
    }

    public var activeSocksPort: Int? {
        get async {
            #if canImport(Mobile)
            return withLock { session.flatMap { Self.controller.activePort($0) } }
            #else
            return nil
            #endif
        }
    }

    public func start(options: OlcRTCStartOptions) async throws {
        try Task.checkCancellation()
        #if canImport(Mobile)
        let target = LegacyRuntimeController.Session()
        try withLock {
            guard session == nil else {
                throw OlcRTCEngineError.invalidProfile("Legacy core is already running or stopping.")
            }
            session = target
        }
        eventPair.continuation.yield("Starting legacy olcRTC on 127.0.0.1:\(options.socksPort)")
        do {
            try await Self.controller.start(target, options: options)
        } catch {
            _ = await Self.controller.stop(target)
            // Keep ownership until explicit stop; callers already clean up failed starts.
            throw error
        }
        #else
        throw OlcRTCEngineError.frameworkMissing
        #endif
    }

    public func waitReady(timeoutMillis: Int) async throws {
        #if canImport(Mobile)
        guard let target = withLock({ session }) else { throw CancellationError() }
        try await Self.controller.waitReady(target, timeoutMillis: timeoutMillis)
        eventPair.continuation.yield("Legacy olcRTC is ready.")
        #else
        throw OlcRTCEngineError.frameworkMissing
        #endif
    }

    public func stop() async {
        #if canImport(Mobile)
        guard let target = withLock({ session }) else { return }
        guard await Self.controller.stop(target) else {
            eventPair.continuation.yield("Legacy shutdown is still pending; reconnect is blocked until cleanup finishes.")
            return
        }
        withLock { if session === target { session = nil } }
        eventPair.continuation.yield("Legacy olcRTC stopped.")
        #endif
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
