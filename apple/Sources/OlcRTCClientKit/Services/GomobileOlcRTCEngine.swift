import Foundation

#if canImport(Mobile)
@preconcurrency import Mobile
#endif

// Mutable Swift state is protected by lock. Mobile.Runtime synchronizes its own
// state; Stop must be able to run concurrently with a blocking WaitReady.
public final class GomobileOlcRTCEngine: OlcRTCEngine, @unchecked Sendable {
    private let eventPair = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(300))
    private let lock = NSLock()
    private var currentSocksPort: Int?
    private var stopRequested = false
    #if canImport(Mobile)
    private var runtime: MobileRuntime?
    #endif

    public init() {}

    deinit {
        eventPair.continuation.finish()
        #if canImport(Mobile)
        if let runtime {
            DispatchQueue.global(qos: .utility).async {
                try? runtime.stop(5_000)
            }
        }
        #endif
    }

    public var events: AsyncStream<String> { eventPair.stream }

    public var isRunning: Bool {
        get async {
            #if canImport(Mobile)
            return withLock { runtime?.isRunning() ?? false }
            #else
            return false
            #endif
        }
    }

    public var activeSocksPort: Int? {
        get async { withLock { currentSocksPort } }
    }

    public func start(options: OlcRTCStartOptions) async throws {
        try Task.checkCancellation()
        #if canImport(Mobile)
        guard let runtime = MobileNew() else { throw OlcRTCEngineError.frameworkMissing }
        try withLock {
            guard self.runtime == nil else {
                throw OlcRTCEngineError.invalidProfile("olcRTC is already running or stopping.")
            }
            self.runtime = runtime
            stopRequested = false
        }
        emit("Starting olcRTC on 127.0.0.1:\(options.socksPort)")
        try await withTaskCancellationHandler {
            try await performBlocking { [self] in
                try withLock {
                    guard !stopRequested, self.runtime === runtime else { throw CancellationError() }
                    try MobileRuntimeConfiguration.apply(options, to: runtime)
                    try runtime.start()
                    currentSocksPort = options.socksPort
                }
            }
            try Task.checkCancellation()
        } onCancel: { [self] in
            requestStop(runtime)
        }
        #else
        throw OlcRTCEngineError.frameworkMissing
        #endif
    }

    public func waitReady(timeoutMillis: Int) async throws {
        try Task.checkCancellation()
        #if canImport(Mobile)
        guard let runtime = withLock({ runtime }) else { throw OlcRTCEngineError.frameworkMissing }
        try await withTaskCancellationHandler {
            try await performBlocking {
                try runtime.waitReady(timeoutMillis)
            }
            try Task.checkCancellation()
        } onCancel: { [self] in
            requestStop(runtime)
        }
        emit("olcRTC is ready.")
        #else
        throw OlcRTCEngineError.frameworkMissing
        #endif
    }

    public func stop() async {
        #if canImport(Mobile)
        let target = withLock {
            stopRequested = true
            return runtime
        }
        #else
        withLock { stopRequested = true }
        #endif
        emit("Stopping olcRTC.")
        #if canImport(Mobile)
        if let runtime = target {
            do {
                try await performBlocking { try runtime.stop(5_000) }
            } catch {
                // Do not forget a still-active runtime or advertise its port as free.
                emit("olcRTC shutdown did not finish: \(error.localizedDescription)")
                return
            }
            withLock {
                if self.runtime === runtime {
                    self.runtime = nil
                    currentSocksPort = nil
                }
            }
        }
        #else
        withLock { currentSocksPort = nil }
        #endif
        emit("olcRTC stopped.")
    }

    #if canImport(Mobile)
    private func requestStop(_ runtime: MobileRuntime) {
        withLock {
            if self.runtime === runtime { stopRequested = true }
        }
        // Capture this generation, never a mutable "current runtime" reference.
        DispatchQueue.global(qos: .utility).async {
            try? runtime.stop(5_000)
        }
    }

    private func performBlocking<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }
    #endif

    private func emit(_ message: String) {
        eventPair.continuation.yield(message)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
