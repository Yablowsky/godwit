import Foundation

/// Records admission/cancellation synchronously, before Apple callbacks hop to
/// an actor. Task scheduling order must not decide whether Stop cancels Start.
public final class TunnelLifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UUID?
    private var cancelled = false

    public init() {}

    public func begin() throws -> UUID {
        try withLock {
            guard current == nil else {
                throw OlcRTCEngineError.invalidProfile("A tunnel session is already active or stopping.")
            }
            let token = UUID()
            current = token
            cancelled = false
            return token
        }
    }

    public func isActive(_ token: UUID) -> Bool {
        withLock { current == token && !cancelled }
    }

    public func cancelCurrent() -> UUID? {
        withLock {
            cancelled = true
            return current
        }
    }

    public func cancel(_ token: UUID) {
        withLock { if current == token { cancelled = true } }
    }

    public func finish(_ token: UUID) {
        withLock {
            if current == token { current = nil; cancelled = false }
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
