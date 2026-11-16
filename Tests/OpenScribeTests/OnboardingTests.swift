import Foundation
import XCTest
@testable import OpenScribe

final class OnboardingTests: XCTestCase {
    private func readiness(mic: Bool, key: Bool, access: Bool = false, paste: Bool = true) -> SetupReadiness {
        SetupReadiness(microphone: mic, accessibility: access, speechKey: key, pasteEnabled: paste)
    }

    // MARK: Readiness split

    func testDictationNeedsOnlyMicrophoneAndKey() {
        XCTAssertTrue(readiness(mic: true, key: true, access: false, paste: true).canDictate)
        XCTAssertTrue(readiness(mic: true, key: true, access: true).canDictate)
        XCTAssertFalse(readiness(mic: false, key: true, access: true).canDictate)
        XCTAssertFalse(readiness(mic: true, key: false, access: true).canDictate)
    }

    func testPasteAnywhereIsSeparateFromDictation() {
        XCTAssertTrue(readiness(mic: false, key: false, access: true).canPasteAnywhere)
        XCTAssertFalse(readiness(mic: true, key: true, access: false).canPasteAnywhere)
        // Paste wanted but not allowed: dictations fall back to Notes.
        XCTAssertTrue(readiness(mic: true, key: true, access: false, paste: true).pasteBlocked)
        XCTAssertFalse(readiness(mic: true, key: true, access: false, paste: false).pasteBlocked)
        XCTAssertFalse(readiness(mic: true, key: true, access: true, paste: true).pasteBlocked)
    }

    func testMissingRequirementFollowsSetupOrder() {
        XCTAssertEqual(readiness(mic: false, key: false).missingRequirement, .microphone)
        XCTAssertEqual(readiness(mic: false, key: true).missingRequirement, .microphone)
        XCTAssertEqual(readiness(mic: true, key: false).missingRequirement, .speechKey)
        XCTAssertNil(readiness(mic: true, key: true, access: false).missingRequirement)
    }

    // MARK: Steps

    func testResumeStartsAtWelcomeOnlyWhenNeverStarted() {
        XCTAssertEqual(OnboardingStep.resume(from: readiness(mic: false, key: false), saved: nil), .welcome)
        XCTAssertEqual(OnboardingStep.resume(from: readiness(mic: true, key: true, access: true), saved: nil), .welcome)
    }

    func testResumeGoesToFirstMissingRequirement() {
        XCTAssertEqual(OnboardingStep.resume(from: readiness(mic: false, key: false), saved: .connect), .microphone)
        XCTAssertEqual(OnboardingStep.resume(from: readiness(mic: false, key: true), saved: .tryIt), .microphone)
        XCTAssertEqual(OnboardingStep.resume(from: readiness(mic: true, key: false), saved: .microphone), .connect)
        XCTAssertEqual(OnboardingStep.resume(from: readiness(mic: true, key: false), saved: .tryIt), .connect)
    }

    func testResumeWithRequirementsMetUsesAccessAndSavedStep() {
        XCTAssertEqual(OnboardingStep.resume(from: readiness(mic: true, key: true, access: false), saved: .connect), .everyApp)
        XCTAssertEqual(OnboardingStep.resume(from: readiness(mic: true, key: true, access: false), saved: .everyApp), .everyApp)
        XCTAssertEqual(OnboardingStep.resume(from: readiness(mic: true, key: true, access: false), saved: .tryIt), .tryIt)
        XCTAssertEqual(OnboardingStep.resume(from: readiness(mic: true, key: true, access: false), saved: .done), .tryIt)
        XCTAssertEqual(OnboardingStep.resume(from: readiness(mic: true, key: true, access: true), saved: .connect), .tryIt)
    }

    func testStepOrderAndProgressDots() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .microphone, .connect, .everyApp, .tryIt, .done])
        XCTAssertEqual(OnboardingStep.allCases.compactMap(\.progressIndex), [0, 1, 2, 3])
        XCTAssertEqual(OnboardingStep.progressCount, 4)
        XCTAssertNil(OnboardingStep.welcome.previous)
        XCTAssertNil(OnboardingStep.done.next)
        XCTAssertEqual(OnboardingStep.connect.next, .everyApp)
        XCTAssertEqual(OnboardingStep.tryIt.previous, .everyApp)
    }

    func testFallbackShortcutWorksWithoutAccessibility() {
        // The one-tap alternative offered when ⌥ Space would need the event tap.
        XCTAssertFalse(OnboardingShortcuts.fallback.needsEventTap)
        XCTAssertTrue(OnboardingShortcuts.fallback.isUsable)
        XCTAssertEqual(OnboardingShortcuts.fallback.display, "⌃⌥ Space")
        XCTAssertTrue(OnboardingShortcuts.alternatives.allSatisfy { !$0.needsEventTap && $0.isUsable })
        if #available(macOS 15, *) { XCTAssertTrue(KeyShortcut.optionSpace.needsEventTap) }
    }

    // MARK: Key verification

    override func setUp() {
        super.setUp()
        VerifyStubProtocol.reset()
        URLProtocol.registerClass(VerifyStubProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(VerifyStubProtocol.self)
        super.tearDown()
    }

    private func settings(_ provider: SpeechProvider) -> AppSettings {
        var settings = AppSettings()
        settings.speechProvider = provider
        settings.speechBaseURL = "https://verify.openscribe.test/v1"
        return settings
    }

    func testVerifyAcceptsAWorkingKeyWithOneAuthenticatedRead() async {
        VerifyStubProtocol.respond(status: 200)
        let result = await ProviderClient().verify(settings: settings(.openAI), key: "  sk-good \n")
        XCTAssertEqual(result, .ok)
        let request = VerifyStubProtocol.lastRequest
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.url?.absoluteString, "https://verify.openscribe.test/v1/models")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-good")
        XCTAssertEqual(VerifyStubProtocol.count, 1)
    }

    func testVerifyReportsRejectedKeys() async {
        for status in [401, 403] {
            VerifyStubProtocol.respond(status: status)
            let result = await ProviderClient().verify(settings: settings(.groq), key: "bad")
            XCTAssertEqual(result, .unauthorized(status: status))
        }
    }

    func testVerifySeparatesOtherErrorsFromRejection() async {
        VerifyStubProtocol.respond(status: 404)
        let result = await ProviderClient().verify(settings: settings(.custom), key: "key")
        XCTAssertEqual(result, .unexpected(status: 404))
        VerifyStubProtocol.respond(status: 503)
        let busy = await ProviderClient().verify(settings: settings(.openAI), key: "key")
        XCTAssertEqual(busy, .unexpected(status: 503))
    }

    func testVerifyReportsUnreachableProvider() async {
        VerifyStubProtocol.fail(URLError(.notConnectedToInternet))
        let result = await ProviderClient().verify(settings: settings(.openRouter), key: "key")
        guard case .unreachable = result else { return XCTFail("Expected unreachable, got \(result)") }
    }

    func testVerifyUsesEachProvidersAuthenticatedEndpoint() async {
        VerifyStubProtocol.respond(status: 200)
        let cases: [(SpeechProvider, String, String)] = [
            (.openRouter, "https://verify.openscribe.test/v1/key", "Bearer abc"),
            (.mistral, "https://verify.openscribe.test/v1/models", "Bearer abc"),
            (.deepgram, "https://verify.openscribe.test/v1/projects", "Token abc"),
            (.assemblyAI, "https://verify.openscribe.test/v1/transcript?limit=1", "abc"),
        ]
        for (provider, url, authorization) in cases {
            let result = await ProviderClient().verify(settings: settings(provider), key: "abc")
            XCTAssertEqual(result, .ok, provider.rawValue)
            XCTAssertEqual(VerifyStubProtocol.lastRequest?.url?.absoluteString, url, provider.rawValue)
            XCTAssertEqual(VerifyStubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), authorization, provider.rawValue)
        }
    }

    func testVerifyRejectsAnEmptyKeyWithoutARequest() async {
        VerifyStubProtocol.respond(status: 200)
        let result = await ProviderClient().verify(settings: settings(.openAI), key: "   ")
        XCTAssertEqual(result, .unauthorized(status: 0))
        XCTAssertEqual(VerifyStubProtocol.count, 0)
    }
}

/// Answers every request with a fixed status, or fails it, and remembers what was asked.
private final class VerifyStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var status = 200
    private static var error: URLError?
    private static var requests: [URLRequest] = []

    static func reset() { lock.lock(); status = 200; error = nil; requests = []; lock.unlock() }
    static func respond(status code: Int) { lock.lock(); status = code; error = nil; lock.unlock() }
    static func fail(_ failure: URLError) { lock.lock(); error = failure; lock.unlock() }
    static var lastRequest: URLRequest? { lock.lock(); defer { lock.unlock() }; return requests.last }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "verify.openscribe.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let status = Self.status, error = Self.error
        Self.lock.unlock()
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
