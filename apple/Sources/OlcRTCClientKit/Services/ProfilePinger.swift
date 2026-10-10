import Foundation

#if canImport(CFNetwork)
import CFNetwork
#endif

#if canImport(Mobile)
@preconcurrency import Mobile
#endif

public enum ProfilePingState: Equatable {
    case success(milliseconds: Int)
    case failure(message: String)
}

public struct ProfilePingResult: Equatable, Sendable {
    public var milliseconds: Int
    public var measuredAt: Date

    public init(milliseconds: Int, measuredAt: Date = Date()) {
        self.milliseconds = milliseconds
        self.measuredAt = measuredAt
    }
}

public protocol ProfilePinging: Sendable {
    func ping(profile: ConnectionProfile) async throws -> ProfilePingResult
}

public enum ProfilePingError: LocalizedError, Equatable {
    case unsupportedPlatform
    case invalidResult
    case invalidHTTPStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            AppLocalization.string("Profile ping is not supported on this platform.")
        case .invalidResult:
            AppLocalization.string("Ping finished without a result.")
        case .invalidHTTPStatus(let status):
            AppLocalization.format("HTTP ping returned status %d.", status)
        }
    }
}

public struct ProfilePinger: ProfilePinging {
    private static let portLeases = ProfilePingPortLeases()

    private let timeoutMillis: Int
    private let pingURL: URL

    // A freshly-established WebRTC tunnel needs more headroom than a direct request:
    // 1.5s was tight enough that healthy-but-slow tunnels timed out and flagged red.
    private static let httpPingTimeout: TimeInterval = 4.0

    public init(
        timeoutMillis: Int = 15_000,
        pingURL: URL = URL(string: "https://www.google.com/generate_204")!
    ) {
        self.timeoutMillis = timeoutMillis
        self.pingURL = pingURL
    }

    public func ping(profile: ConnectionProfile) async throws -> ProfilePingResult {
        try Task.checkCancellation()
        let socksPort = await Self.portLeases.reserveTemporaryPort()
        let profile = preparedProfileForPing(profile, socksPort: socksPort)

        do {
            #if canImport(Mobile)
            let result = try await pingWithMobile(profile: profile)
            #elseif os(macOS)
            let result = try await pingWithProcess(profile: profile)
            #else
            throw ProfilePingError.unsupportedPlatform
            #endif
            await Self.portLeases.release(socksPort)
            return result
        } catch {
            await Self.portLeases.release(socksPort)
            throw error
        }
    }

    private func preparedProfileForPing(_ profile: ConnectionProfile, socksPort: Int) -> ConnectionProfile {
        var profile = profile.normalizedForCurrentDefaults()
        let baseClientID = profile.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? profile.id.uuidString
            : profile.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.clientID = "\(baseClientID)-ping-\(UUID().uuidString.prefix(8))"
        profile.socksPort = socksPort
        profile.socksUser = ""
        profile.socksPass = ""
        return profile
    }

    #if canImport(Mobile)
    private func pingWithMobile(profile: ConnectionProfile) async throws -> ProfilePingResult {
        let options = OlcRTCStartOptions(profile: profile)
        let timeout = timeoutMillis
        let targetURL = pingURL.absoluteString
        // Runtime.Ping owns a separate bounded probe; Runtime.Stop does NOT cancel
        // that probe. Keep the port lease until it returns and discard cancelled results.
        let measured: Int64 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    guard let runtime = MobileNew() else { throw OlcRTCEngineError.frameworkMissing }
                    try MobileRuntimeConfiguration.apply(options, to: runtime)
                    var result: Int64 = -1
                    try runtime.ping(
                        options.carrierName, transportName: options.transportName,
                        roomID: options.roomID, deviceID: options.clientID, keyHex: options.keyHex,
                        socksPort: options.socksPort, timeoutMillis: timeout, pingURL: targetURL,
                        vp8FPS: options.vp8FPS, vp8BatchSize: options.vp8BatchSize, ret0_: &result
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()

        guard measured >= 0 else {
            throw ProfilePingError.invalidResult
        }
        return ProfilePingResult(milliseconds: Int(measured))
    }
    #endif

    #if os(macOS)
    private func pingWithProcess(profile: ConnectionProfile) async throws -> ProfilePingResult {
        let engine = ProcessOlcRTCEngine()
        let options = OlcRTCStartOptions(profile: profile)

        do {
            try await engine.start(options: options)
            // Ping uses a fixed startup budget (shorter than a real connection): a profile
            // that needs longer than this to come up is treated as too slow for a quick check.
            try await engine.waitReady(timeoutMillis: timeoutMillis)
            let socksPort = await engine.activeSocksPort ?? options.socksPort
            let milliseconds = try await httpPingThroughSOCKS(port: socksPort)
            await engine.stop()
            return ProfilePingResult(milliseconds: milliseconds)
        } catch {
            await engine.stop()
            throw error
        }
    }

    private func httpPingThroughSOCKS(port: Int) async throws -> Int {
        let session = makeSOCKSSession(port: port)
        defer {
            session.invalidateAndCancel()
        }

        _ = try? await singleHTTPPing(session: session, timeout: Self.httpPingTimeout)

        var best: Int?
        for index in 0..<3 {
            if index > 0 {
                try await Task.sleep(nanoseconds: 80_000_000)
            }
            let measured = try await singleHTTPPing(session: session, timeout: Self.httpPingTimeout)
            best = min(best ?? measured, measured)
        }

        guard let best else {
            throw ProfilePingError.invalidResult
        }
        return best
    }

    private func makeSOCKSSession(port: Int) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.httpPingTimeout
        configuration.timeoutIntervalForResource = Self.httpPingTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        #if canImport(CFNetwork)
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: true,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: port,
        ]
        #endif

        return URLSession(configuration: configuration)
    }

    private func singleHTTPPing(session: URLSession, timeout: TimeInterval) async throws -> Int {
        var request = URLRequest(url: pingURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"

        let startedAt = Date()
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProfilePingError.invalidResult
        }
        guard (200..<400).contains(httpResponse.statusCode) else {
            throw ProfilePingError.invalidHTTPStatus(httpResponse.statusCode)
        }
        return max(1, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }
    #endif
}

private actor ProfilePingPortLeases {
    private var leasedPorts: Set<Int> = []

    func reserveTemporaryPort() -> Int {
        let range = 49_152...65_535
        for port in Array(range).shuffled() where !leasedPorts.contains(port) && PortAvailability.isLocalTCPPortAvailable(port) {
            leasedPorts.insert(port)
            return port
        }

        for port in ConnectionProfile.socksPortRange where !leasedPorts.contains(port) && PortAvailability.isLocalTCPPortAvailable(port) {
            leasedPorts.insert(port)
            return port
        }

        let fallback = PortAvailability.randomAvailableTCPPort()
        leasedPorts.insert(fallback)
        return fallback
    }

    func release(_ port: Int) {
        leasedPorts.remove(port)
    }
}
