import Foundation

// The old Go API is process-global. All singleton calls are ordered on one
// queue; ownership survives a shutdown timeout until native Stop really returns.
final class LegacyRuntimeController: @unchecked Sendable {
    struct API: Sendable {
        var start: @Sendable (OlcRTCStartOptions) throws -> Void
        var waitReady: @Sendable (Int) throws -> Void
        var stop: @Sendable () -> Void
        var isRunning: @Sendable () -> Bool
    }

    final class Session: @unchecked Sendable {
        // Accessed only under the controller lock.
        fileprivate var stopping = false
    }

    private let api: API
    private let queue = DispatchQueue(label: "godwit.legacy-runtime", qos: .userInitiated)
    private let lock = NSLock()
    private var current: Session?
    private var port: Int?
    private var stopWaiters: [@Sendable (Bool) -> Void] = []

    init(api: API) { self.api = api }

    func isRunning(_ session: Session) -> Bool {
        withLock { current === session && (session.stopping || api.isRunning()) }
    }

    func activePort(_ session: Session) -> Int? {
        withLock { current === session ? port : nil }
    }

    func start(_ session: Session, options: OlcRTCStartOptions) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                withLock {
                    guard !session.stopping else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard current == nil else {
                        continuation.resume(throwing: OlcRTCEngineError.invalidProfile(
                            "Legacy core is already running or still stopping."))
                        return
                    }
                    current = session
                    queue.async { [self] in
                        let result = Result { try withLock {
                            guard current === session, !session.stopping else { throw CancellationError() }
                            try api.start(options)
                            port = options.socksPort
                        } }
                        continuation.resume(with: result)
                    }
                }
            }
            try Task.checkCancellation()
        } onCancel: { [self] in
            requestStop(session)
        }
    }

    func waitReady(_ session: Session, timeoutMillis: Int) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(1, timeoutMillis)) * 1_000_000
        try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        withLock {
                            guard current === session, !session.stopping else {
                                continuation.resume(throwing: CancellationError())
                                return
                            }
                            queue.async { [self] in
                            continuation.resume(with: Result {
                                try withLock {
                                    guard current === session, !session.stopping else { throw CancellationError() }
                                }
                                // Short slices let queued Stop run promptly without allowing
                                // a stale WaitReady to attach to the next global session.
                                try api.waitReady(100)
                            })
                            }
                        }
                    }
                    try Task.checkCancellation()
                    try withLock {
                        guard current === session, !session.stopping else { throw CancellationError() }
                    }
                    return
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || !isRunning(session)
                        || DispatchTime.now().uptimeNanoseconds >= deadline { throw error }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            }
        } onCancel: { [self] in
            requestStop(session)
        }
    }

    // false means native Stop is still running. Never release the singleton on timeout.
    func stop(_ session: Session, timeoutMillis: Int = 5_000) async -> Bool {
        await withCheckedContinuation { continuation in
            let completion = LegacyStopCompletion(continuation)
            requestStop(session) { completion.finish($0) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(timeoutMillis)) {
                completion.finish(false)
            }
        }
    }

    func requestStop(_ session: Session, completion: (@Sendable (Bool) -> Void)? = nil) {
        withLock {
            let alreadyStopping = session.stopping
            session.stopping = true
            guard current === session else {
                completion?(true)
                return
            }
            if let completion { stopWaiters.append(completion) }
            guard !alreadyStopping else { return }
            queue.async { [self] in
                api.stop()
                let waiters = withLock {
                    current = nil
                    port = nil
                    let waiters = stopWaiters
                    stopWaiters.removeAll()
                    return waiters
                }
                for waiter in waiters { waiter(true) }
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private final class LegacyStopCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func finish(_ result: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: result)
    }
}
