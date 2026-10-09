import Foundation

// The opaque token never escapes this owner. NotificationCenter supports
// removal from any thread, including a main-actor owner's nonisolated deinit.
final class NotificationObservation: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) { self.token = token }

    deinit { NotificationCenter.default.removeObserver(token) }
}
