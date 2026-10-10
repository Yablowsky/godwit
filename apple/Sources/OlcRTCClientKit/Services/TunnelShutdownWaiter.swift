import Foundation

public enum TunnelShutdownError: LocalizedError {
    case timedOut

    public var errorDescription: String? {
        "VPN shutdown timed out. The tunnel may still be disconnecting; retry Stop before starting another VPN."
    }
}

@MainActor
enum TunnelShutdownWaiter {
    static func wait(
        timeout: Duration = .seconds(15),
        pollInterval: Duration = .milliseconds(100),
        isDisconnected: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if isDisconnected() { return }
            guard ContinuousClock.now < deadline else { throw TunnelShutdownError.timedOut }
            try await Task.sleep(for: pollInterval)
        }
    }
}
