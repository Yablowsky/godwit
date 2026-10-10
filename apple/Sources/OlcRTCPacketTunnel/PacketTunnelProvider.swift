import Foundation
import NetworkExtension
import OlcRTCClientKit
@preconcurrency import Tun2SocksKit

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private enum Constants {
        static let tunnelAddress = "198.18.0.1"
        static let tunnelSubnetMask = "255.255.255.0"
        static let mapDNSAddress = "198.18.0.2"
        static let mapDNSNetwork = "198.18.0.0"
        static let mapDNSNetmask = "255.255.0.0"
        static let mtu = 8500
    }

    @MainActor
    private final class Session {
        let id: UUID
        let engine = GomobileOlcRTCEngine()
        var startup: Task<Void, Never>?
        var monitor: Task<Void, Never>?
        var forwarder: PacketTunnelForwarder?
        var configFileURL: URL?
        var stopping = false

        init(id: UUID) { self.id = id }
    }

    private let admission = TunnelLifecycleGate()
    @MainActor private var session: Session?
    @MainActor private var shutdown: Task<Void, Never>?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let completion = TunnelCompletion<Error?>(completionHandler)
        let token: UUID
        do { token = try admission.begin() } catch {
            completion(error)
            return
        }
        // Snapshot Foundation dictionaries as Swift values before crossing actors.
        let configuration: PacketTunnelConfiguration
        do {
            configuration = try PacketTunnelConfiguration(
                providerConfiguration: (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
                startOptions: options
            )
        } catch {
            admission.finish(token)
            completion(error)
            return
        }
        Task { @MainActor in
            guard admission.isActive(token) else {
                admission.finish(token)
                completion(CancellationError())
                return
            }
            guard session == nil, shutdown == nil else {
                admission.finish(token)
                completion(OlcRTCEngineError.invalidProfile("A tunnel session is already active or stopping."))
                return
            }
            let session = Session(id: token)
            self.session = session
            session.startup = Task { @MainActor in
                defer { session.startup = nil }
                do {
                    try checkActive(session)
                    try await session.engine.start(options: OlcRTCStartOptions(profile: configuration.connectionProfile))
                    try checkActive(session)
                    try await session.engine.waitReady(timeoutMillis: max(
                        configuration.startTimeoutMillis, ConnectionProfile.defaultStartTimeoutMillis
                    ))
                    try checkActive(session)
                    try await applyNetworkSettings()
                    try checkActive(session)
                    try await startTun2Socks(configuration: configuration, session: session)
                    try checkActive(session)
                    monitor(session)
                    completion(nil)
                } catch {
                    if !session.stopping {
                        // Never join this startup task from itself.
                        await beginShutdown(session, waitForStartup: false).value
                    }
                    completion(error)
                }
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        let completion = TunnelCompletion<Void> { _ in completionHandler() }
        let token = admission.cancelCurrent()
        Task { @MainActor in
            if let session, session.id == token {
                await beginShutdown(session).value
            }
            // Only signal completion after the native forwarder and runtime exit.
            completion(())
        }
    }

    @MainActor
    private func checkActive(_ session: Session) throws {
        try Task.checkCancellation()
        guard self.session === session, !session.stopping,
              admission.isActive(session.id) else { throw CancellationError() }
    }

    @MainActor
    private func applyNetworkSettings() async throws {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: Constants.tunnelAddress)
        settings.mtu = Constants.mtu as NSNumber

        let ipv4Settings = NEIPv4Settings(
            addresses: [Constants.tunnelAddress],
            subnetMasks: [Constants.tunnelSubnetMask]
        )
        ipv4Settings.includedRoutes = [NEIPv4Route.default()]
        ipv4Settings.excludedRoutes = [
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
        ]
        settings.ipv4Settings = ipv4Settings

        let dnsSettings = NEDNSSettings(servers: [Constants.mapDNSAddress])
        dnsSettings.matchDomains = [""]
        settings.dnsSettings = dnsSettings

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    @MainActor
    private func startTun2Socks(configuration: PacketTunnelConfiguration, session: Session) async throws {
        let socksPort = await session.engine.activeSocksPort ?? configuration.socksPort
        try checkActive(session)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("olcrtc-tun2socks-\(UUID().uuidString).yml")
        try tun2socksConfiguration(
            socksPort: socksPort,
            debugLogging: configuration.debugLogging
        ).write(to: fileURL, atomically: true, encoding: .utf8)
        session.configFileURL = fileURL
        let forwarder = PacketTunnelForwarder()
        session.forwarder = forwarder
        forwarder.start(fileURL: fileURL)
    }

    @MainActor
    private func beginShutdown(_ session: Session, waitForStartup: Bool = true) -> Task<Void, Never> {
        if let shutdown { return shutdown }
        admission.cancel(session.id)
        session.stopping = true
        session.startup?.cancel()
        session.monitor?.cancel()
        let startup = waitForStartup ? session.startup : nil
        let task = Task { @MainActor in
            // Break a blocking WaitReady before joining startup.
            await session.engine.stop()
            await startup?.value
            if let forwarder = session.forwarder {
                repeat {
                    forwarder.requestStop()
                    if forwarder.exitCode != nil { break }
                    await pauseDuringShutdown()
                } while true
                session.forwarder = nil
            }
            // A Go shutdown timeout is not proof that the runtime has exited.
            // Keep the session owned; NetworkExtension controls the final OS deadline.
            repeat {
                await session.engine.stop()
                if !(await session.engine.isRunning) { break }
                await pauseDuringShutdown()
            } while true
            if let fileURL = session.configFileURL {
                try? FileManager.default.removeItem(at: fileURL)
                session.configFileURL = nil
            }
            if self.session === session { self.session = nil }
            self.shutdown = nil
            self.admission.finish(session.id)
        }
        shutdown = task
        return task
    }

    @MainActor
    private func monitor(_ session: Session) {
        session.monitor = Task { @MainActor [weak self, weak session] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let session, self.session === session, !session.stopping else { return }
                let runtimeRunning = await session.engine.isRunning
                guard !Task.isCancelled, !session.stopping else { return }
                if !runtimeRunning || session.forwarder?.exitCode != nil {
                    let error = OlcRTCEngineError.invalidProfile("The tunnel runtime or packet forwarder exited unexpectedly.")
                    await self.beginShutdown(session).value
                    self.cancelTunnelWithError(error)
                    return
                }
            }
        }
    }

    private func pauseDuringShutdown() async {
        // Cleanup must keep waiting even if the startup task that requested it was cancelled.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(100)) {
                continuation.resume()
            }
        }
    }

    private func tun2socksConfiguration(
        socksPort: Int,
        debugLogging: Bool
    ) -> String {
        """
        tunnel:
          mtu: \(Constants.mtu)
          ipv4: \(Constants.tunnelAddress)
        socks5:
          port: \(socksPort)
          address: 127.0.0.1
          udp: 'tcp'
        mapdns:
          address: \(Constants.mapDNSAddress)
          port: 53
          network: \(Constants.mapDNSNetwork)
          netmask: \(Constants.mapDNSNetmask)
          cache-size: 10000
        misc:
          task-stack-size: 24576
          tcp-buffer-size: 4096
          connect-timeout: 10000
          tcp-read-write-timeout: 300000
          udp-read-write-timeout: 60000
          log-file: stderr
          log-level: \(debugLogging ? "debug" : "warn")
          limit-nofile: 65535
        """
    }
}

// NetworkExtension's legacy completion may be called asynchronously. Transfer
// sole ownership into this synchronized, one-shot holder before scheduling work.
private final class TunnelCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Value) -> Void)?

    init(_ callback: @escaping (Value) -> Void) { self.callback = callback }

    func callAsFunction(_ value: Value) {
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?(value)
    }
}

// The C forwarder is blocking and has no Swift cancellation support. The lock
// protects only Swift bookkeeping, never the blocking native run() call.
private final class PacketTunnelForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private var stopping = false
    private var result: Int32?

    var exitCode: Int32? { withLock { result } }

    func start(fileURL: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let shouldRun = withLock {
                if stopping { result = 0; return false }
                return true
            }
            guard shouldRun else { return }
            let code = Socks5Tunnel.run(withConfig: .file(path: fileURL))
            withLock { result = code }
        }
    }

    func requestStop() {
        let needsStop = withLock { stopping = true; return result == nil }
        // Repeated by cleanup: a quit issued before native initialization can be lost.
        if needsStop { Socks5Tunnel.quit() }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
