import Foundation
import XCTest
@testable import OlcRTCClientKit

@MainActor
final class ClientViewModelSubscriptionRefreshTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "ClientViewModelSubscriptionRefreshTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        SubscriptionURLProtocol.reset()
    }

    override func tearDown() async throws {
        SubscriptionURLProtocol.reset()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testAutomaticallyRefreshesSubscriptionUsingRefreshInterval() async throws {
        let url = URL(string: "https://example.test/sub")!
        SubscriptionURLProtocol.setBody(initialSubscription(nodeName: "RU-1"), for: url)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let viewModel = ClientViewModel(
            engine: StubOlcRTCEngine(),
            store: ProfileStore(defaults: defaults),
            subscriptionFetcher: SubscriptionFetcher(urlSession: session),
            profilePinger: StubProfilePinger()
        )

        viewModel.importValue(url.absoluteString)
        let didImport = await waitUntil {
            viewModel.profiles.first?.name == "RU-1" && !viewModel.isImporting
        }
        XCTAssertTrue(didImport)

        let subscriptionID = try XCTUnwrap(viewModel.profiles.first?.subscription?.id)
        let firstFetchedAt = try XCTUnwrap(viewModel.profiles.first?.subscription?.lastFetchedAtUnix)

        SubscriptionURLProtocol.setBody(initialSubscription(nodeName: "RU-2"), for: url)
        let didRefresh = await waitUntil(timeout: 3) {
            viewModel.profiles.first?.name == "RU-2"
        }

        XCTAssertTrue(didRefresh)
        XCTAssertEqual(viewModel.profiles.first?.subscription?.id, subscriptionID)
        XCTAssertGreaterThan(
            try XCTUnwrap(viewModel.profiles.first?.subscription?.lastFetchedAtUnix),
            firstFetchedAt
        )
    }

    private func initialSubscription(nodeName: String) -> String {
        """
        #name: Example
        #refresh: 1s

        olcrtc://wbstream?datachannel@room-01#d823fa01cb3e0609b67322f7cf984c4ee2e4ce2e294936fc24ef38c9e59f4799$RU
        ##name: \(nodeName)
        """
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        predicate: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }
}

private final class StubOlcRTCEngine: OlcRTCEngine {
    private let eventStream = AsyncStream<String> { continuation in
        continuation.finish()
    }

    var events: AsyncStream<String> {
        eventStream
    }

    var isRunning: Bool {
        get async { false }
    }

    var activeSocksPort: Int? {
        get async { nil }
    }

    func start(options: OlcRTCStartOptions) async throws {
        _ = options
    }

    func waitReady(timeoutMillis: Int) async throws {
        _ = timeoutMillis
    }

    func stop() async {}
}

private struct StubProfilePinger: ProfilePinging {
    func ping(profile: ConnectionProfile) async throws -> ProfilePingResult {
        _ = profile
        return ProfilePingResult(milliseconds: 1)
    }
}

private final class SubscriptionURLProtocol: URLProtocol {
    private final class Responses: @unchecked Sendable {
        let lock = NSLock()
        var bodies: [URL: String] = [:]
    }
    private static let responses = Responses()

    static func setBody(_ body: String, for url: URL) {
        responses.lock.lock()
        responses.bodies[url] = body
        responses.lock.unlock()
    }

    static func reset() {
        responses.lock.lock()
        responses.bodies.removeAll()
        responses.lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body = Self.body(for: url)
        let statusCode = body == nil ? 404 : 200
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body {
            client?.urlProtocol(self, didLoad: Data(body.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(for url: URL) -> String? {
        responses.lock.lock()
        defer { responses.lock.unlock() }
        return responses.bodies[url]
    }
}
