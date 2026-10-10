import Foundation

#if os(iOS)
import NetworkExtension

public enum PacketTunnelManagerError: LocalizedError {
    case providerBundleIdentifierMissing
    case providerDisconnected
    case startTimedOut
    case alreadyActive

    public var errorDescription: String? {
        switch self {
        case .providerBundleIdentifierMissing:
            "Packet tunnel provider bundle identifier is missing."
        case .providerDisconnected:
            "The iOS VPN tunnel stopped before it reported a connection."
        case .startTimedOut:
            "Timed out while waiting for the iOS VPN tunnel to connect."
        case .alreadyActive:
            "The iOS VPN tunnel is already active or still disconnecting."
        }
    }
}

@MainActor
public final class PacketTunnelManager {
    private let providerBundleIdentifier: String
    private let localizedDescription: String
    private var manager: NETunnelProviderManager?
    private var statusObserver: NotificationObservation?
    public var onStatusChange: ((ClientStatus) -> Void)?

    public init(
        providerBundleIdentifier: String? = nil,
        localizedDescription: String = "Godwit Legacy"
    ) {
        self.providerBundleIdentifier = providerBundleIdentifier
            ?? Bundle.main.bundleIdentifier.map { "\($0).PacketTunnel" }
            ?? "com.egorozh.godwit.legacy.PacketTunnel"
        self.localizedDescription = localizedDescription
    }

    public func refreshStatus() async throws {
        let managers = try await matchingManagers()
        if let existing = managers.first(where: { !Self.isDisconnected($0.connection) }) ?? managers.first {
            observe(existing)
        } else {
            onStatusChange?(.stopped)
        }
    }

    public static func canAccessPacketTunnelPreferences() async -> Bool {
        do {
            _ = try await loadAllManagers()
            return true
        } catch {
            return false
        }
    }

    public func start(
        profile: ConnectionProfile,
        eventHandler: ((String) async -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let configuration = PacketTunnelConfiguration(profile: profile.normalizedForCurrentDefaults())
        await eventHandler?("Preparing iOS VPN configuration.")
        let manager = try await loadOrCreateManager()
        try Task.checkCancellation()
        guard Self.isDisconnected(manager.connection) else { throw PacketTunnelManagerError.alreadyActive }
        await eventHandler?("Saving iOS VPN configuration.")
        try await configure(manager: manager, configuration: configuration)
        await eventHandler?("Requesting iOS VPN tunnel start.")
        try Task.checkCancellation()
        try manager.connection.startVPNTunnel(options: configuration.providerConfiguration)
        await eventHandler?("Waiting up to \(configuration.startTimeoutMillis / 1_000)s for iOS VPN tunnel.")
        try await waitUntilConnected(
            manager.connection,
            timeoutMillis: configuration.startTimeoutMillis,
            eventHandler: eventHandler
        )
    }

    public func stop() async throws {
        let managers = try await matchingManagers()
        // Include the cached connection: it can be ahead of the preferences snapshot.
        let connections = managers.map(\.connection) + (manager.map { [$0.connection] } ?? [])
        for connection in connections where !Self.isDisconnected(connection) {
            connection.stopVPNTunnel()
        }
        try await TunnelShutdownWaiter.wait {
            connections.allSatisfy(Self.isDisconnected)
        }
        onStatusChange?(.stopped)
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await matchingManagers()
        let manager = managers.first(where: { !Self.isDisconnected($0.connection) })
            ?? managers.first ?? NETunnelProviderManager()
        observe(manager)
        return manager
    }

    private func matchingManagers() async throws -> [NETunnelProviderManager] {
        try await Self.loadAllManagers().filter {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerBundleIdentifier
        }
    }

    private static func isDisconnected(_ connection: NEVPNConnection) -> Bool {
        connection.status == .disconnected || connection.status == .invalid
    }

    private func observe(_ manager: NETunnelProviderManager) {
        statusObserver = nil
        self.manager = manager
        statusObserver = NotificationObservation(NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publishStatus() }
        })
        publishStatus()
    }

    private func publishStatus() {
        guard let manager else { return }
        switch manager.connection.status {
        case .connected: onStatusChange?(.ready)
        case .connecting, .reasserting: onStatusChange?(.starting)
        case .disconnecting: onStatusChange?(.stopping)
        case .disconnected, .invalid: onStatusChange?(.stopped)
        @unknown default: break
        }
    }

    private func configure(
        manager: NETunnelProviderManager,
        configuration: PacketTunnelConfiguration
    ) async throws {
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = providerBundleIdentifier
        tunnelProtocol.serverAddress = configuration.carrierName
        tunnelProtocol.providerConfiguration = configuration.providerMetadata
        tunnelProtocol.includeAllNetworks = true
        tunnelProtocol.excludeLocalNetworks = true
        tunnelProtocol.enforceRoutes = true

        manager.localizedDescription = localizedDescription
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true

        try await save(manager)
        try Task.checkCancellation()
        try await load(manager)
        try Task.checkCancellation()
    }

    private func waitUntilConnected(
        _ connection: NEVPNConnection,
        timeoutMillis: Int,
        eventHandler: ((String) async -> Void)?
    ) async throws {
        let timeout = UInt64(max(timeoutMillis, 10_000)) * 1_000_000
        let startedAt = ContinuousClock.now
        let deadline = startedAt.advanced(by: .nanoseconds(timeout))
        let disconnectedGraceDeadline = startedAt.advanced(by: .seconds(5))
        var lastStatus: NEVPNStatus?
        var sawConnectionAttempt = false

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let status = connection.status
            if status != lastStatus {
                await eventHandler?("iOS VPN status: \(Self.statusDescription(status)).")
                lastStatus = status
            }

            switch status {
            case .connected:
                return
            case .invalid:
                throw PacketTunnelManagerError.providerBundleIdentifierMissing
            case .disconnected:
                if sawConnectionAttempt || ContinuousClock.now >= disconnectedGraceDeadline {
                    throw PacketTunnelManagerError.providerDisconnected
                }
            case .disconnecting:
                if sawConnectionAttempt {
                    throw PacketTunnelManagerError.providerDisconnected
                }
            case .connecting, .reasserting:
                sawConnectionAttempt = true
            @unknown default:
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw PacketTunnelManagerError.startTimedOut
    }

    private static func statusDescription(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid:
            "invalid"
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .connected:
            "connected"
        case .reasserting:
            "reasserting"
        case .disconnecting:
            "disconnecting"
        @unknown default:
            "unknown"
        }
    }

    private static func loadAllManagers() async throws -> [NETunnelProviderManager] {
        // Transfer the result of Apple's legacy callback once. From this point
        // onward only MainActor accesses these managers.
        let loaded: LoadedManagers = try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: LoadedManagers(values: managers ?? []))
            }
        }
        return loaded.values
    }

    private struct LoadedManagers: @unchecked Sendable {
        let values: [NETunnelProviderManager]
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    private func load(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }
}
#endif
