import Foundation
import XCTest
@testable import FixWise

final class VerticalSliceTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.requestHandler = nil
    }

    @MainActor
    func testRecommendedFPSUsesConfiguredThresholds() {
        let service = CameraService()

        XCTAssertEqual(service.recommendedFPS(for: 0.01), service.config.idleFPS)
        XCTAssertEqual(service.recommendedFPS(for: 0.10), service.config.activeFPS)
        XCTAssertEqual(service.recommendedFPS(for: 0.25), service.config.highActivityFPS)
    }

    func testPromptMessageEncodingMatchesBackendContract() throws {
        let service = WebSocketService(
            config: .init(serverURL: URL(string: "ws://localhost:8000/ws/session")!)
        )
        let message = WebSocketService.OutgoingMessage.prompt(
            .init(
                sessionId: "session-1",
                timestamp: 10,
                text: "What should I do next?",
                mode: .general
            )
        )

        let data = try service.encode(message)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["type"] as? String, "prompt")
        XCTAssertEqual(json["sessionId"] as? String, "session-1")
        XCTAssertEqual(json["text"] as? String, "What should I do next?")
        XCTAssertEqual(json["mode"] as? String, "general")
    }

    func testPromptSendReturnsFalseWhileDisconnected() {
        let service = WebSocketService(
            config: .init(serverURL: URL(string: "ws://localhost:8000/ws/session")!)
        )

        XCTAssertFalse(service.sendPrompt("What should I do next?", sessionId: "session-1", mode: .general))
    }

    func testIncomingResponseDecodingMapsAnnotations() throws {
        let service = WebSocketService(
            config: .init(serverURL: URL(string: "ws://localhost:8000/ws/session")!)
        )
        let payload = """
        {
          "type": "response",
          "sessionId": "session-1",
          "text": "Turn the highlighted valve.",
          "annotations": [
            {
              "type": "circle",
              "label": "Valve",
              "x": 0.45,
              "y": 0.62,
              "radius": 0.08,
              "color": "#FF6B35"
            }
          ],
          "stepNumber": 1,
          "safetyWarning": null,
          "mode": "general",
          "suggestedMode": "car"
        }
        """.data(using: .utf8)!

        let decoded = try service.decode(payload)

        XCTAssertEqual(decoded.type, "response")
        XCTAssertEqual(decoded.sessionId, "session-1")
        XCTAssertEqual(decoded.annotations?.first?.label, "Valve")
        XCTAssertEqual(decoded.mode, "general")
        XCTAssertEqual(decoded.suggestedMode, "car")
    }

    func testIncomingResponseDecodingMapsAudio() throws {
        let service = WebSocketService(
            config: .init(serverURL: URL(string: "ws://localhost:8000/ws/session")!)
        )
        let payload = """
        {
          "type": "response",
          "text": "Turn the valve clockwise.",
          "audio": "UklGRg=="
        }
        """.data(using: .utf8)!

        let decoded = try service.decode(payload)

        XCTAssertEqual(decoded.text, "Turn the valve clockwise.")
        XCTAssertEqual(decoded.audio, "UklGRg==")
    }

    func testPromptEncodingReflectsModeSwitchesAcrossMessages() throws {
        let service = WebSocketService(
            config: .init(serverURL: URL(string: "ws://localhost:8000/ws/session")!)
        )

        let first = try service.encode(
            .prompt(
                .init(
                    sessionId: "session-1",
                    timestamp: 10,
                    text: "What should I inspect next?",
                    mode: .general
                )
            )
        )
        let second = try service.encode(
            .prompt(
                .init(
                    sessionId: "session-1",
                    timestamp: 11,
                    text: "What should I inspect next?",
                    mode: .car
                )
            )
        )

        let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let secondJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: second) as? [String: Any])

        XCTAssertEqual(firstJSON["mode"] as? String, "general")
        XCTAssertEqual(secondJSON["mode"] as? String, "car")
    }

    func testGuidanceModeRestoresPersistedChoice() {
        let defaults = tempUserDefaults()
        defaults.set(GuidanceMode.car.rawValue, forKey: GuidanceMode.storageKey)

        XCTAssertEqual(GuidanceMode.storedSelection(in: defaults), .car)
        XCTAssertEqual(GuidanceMode.resolved(rawValue: "unknown"), .general)
    }

    func testAnnotationMappingPreservesCirclePayload() {
        let webSocketAnnotation = WebSocketService.AnnotationData(
            type: "circle",
            label: "Valve",
            x: 0.45,
            y: 0.62,
            radius: 0.08,
            color: "#FF6B35",
            from: nil,
            to: nil
        )

        let annotation = Annotation(from: webSocketAnnotation)

        XCTAssertEqual(annotation.type, .circle)
        XCTAssertEqual(annotation.label, "Valve")
        XCTAssertEqual(annotation.x, 0.45)
        XCTAssertEqual(annotation.y, 0.62)
    }

    @MainActor
    func testSafetyNoticeCanResumeListening() {
        let state = SessionState()

        _ = state.startSession()
        state.didConnect()
        state.handleSafetyNotice("Gas line work is blocked.")

        XCTAssertEqual(state.overlay, .safety("Gas line work is blocked."))

        state.resumeListening()

        XCTAssertNil(state.overlay)
        XCTAssertEqual(state.phase, .active(subState: .listening))
    }

    @MainActor
    func testDidConnectClearsTransientErrorState() {
        let state = SessionState()

        _ = state.startSession()
        state.handleError("The backend connection was lost.", shouldStopTimer: true)

        state.didConnect()

        XCTAssertEqual(state.lastGuidanceText, "")
        XCTAssertNil(state.overlay)
        XCTAssertEqual(state.phase, .active(subState: .listening))
    }

    func testGuidanceTextSanitizerHidesInternalSessionLeakText() {
        let text = GuidanceTextSanitizer.userFacing(
            "I have your latest frame for session F6BE7519. For 'what now', keep the camera steady."
        )

        XCTAssertEqual(
            text,
            "I can see the area you mean. Hold the phone steady and I'll guide the next small step."
        )
    }

    func testLoopbackHostDetectionRecognizesLocalEndpoints() {
        XCTAssertTrue(AppConfig.isLoopbackHost(URL(string: "http://127.0.0.1:8000")!))
        XCTAssertTrue(AppConfig.isLoopbackHost(URL(string: "ws://localhost:8000/ws/session")!))
        XCTAssertFalse(AppConfig.isLoopbackHost(URL(string: "https://api.fixwise.app")!))
    }

    func testDeploymentBadgeRecognizesHostedBetaBackend() {
        XCTAssertEqual(
            AppConfig.deploymentBadgeText(for: URL(string: "https://fixwise-backend.onrender.com")!),
            "Hosted Beta"
        )
        XCTAssertNil(
            AppConfig.deploymentBadgeText(for: URL(string: "https://example.com")!)
        )
    }

    func testGuidanceReadinessWaitsForSceneFrameBeforePrompting() {
        let readiness = GuidanceInputReadiness.resolve(
            hasStartedSession: true,
            canSendInteractiveMessages: true,
            hasSessionId: true,
            hasVisualContext: false,
            isTerminal: false
        )

        XCTAssertEqual(readiness, .waitingForSceneFrame)
        XCTAssertFalse(readiness.canInteract)
        XCTAssertEqual(
            readiness.blockedMessage(for: "asking a question"),
            "Hold the phone on the task for a moment so FixWise can see it before asking a question."
        )
    }

    func testGuidanceReadinessBecomesInteractiveOnceConnectionAndSceneAreReady() {
        let readiness = GuidanceInputReadiness.resolve(
            hasStartedSession: true,
            canSendInteractiveMessages: true,
            hasSessionId: true,
            hasVisualContext: true,
            isTerminal: false
        )

        XCTAssertEqual(readiness, .ready)
        XCTAssertTrue(readiness.canInteract)
        XCTAssertEqual(
            readiness.bannerText,
            "Ask naturally about what you see, what to do next, or what looks unsafe."
        )
    }

    @MainActor
    func testSessionStateTracksConversationAndRecapContent() {
        let state = SessionState()

        _ = state.startSession()
        state.recordUserTurn("What should I do next?")
        state.didReceiveResponse(
            newAnnotations: [],
            text: "Tighten the valve clockwise a quarter turn.",
            nextAction: "Tighten the valve clockwise a quarter turn.",
            needsCloserFrame: true,
            followUpPrompts: [
                "Show me the fastener",
                "What should I do next?"
            ],
            confidence: .high,
            summary: "FixWise guided a valve-tightening step."
        )

        XCTAssertEqual(state.conversationTurns.count, 2)
        XCTAssertEqual(state.visibleFollowUpPrompts, ["Show me the fastener", "What should I do next?"])
        XCTAssertEqual(state.recapSummaryText, "FixWise guided a valve-tightening step.")
        XCTAssertEqual(state.recapNextActionText, "Tighten the valve clockwise a quarter turn.")
        XCTAssertEqual(state.guidanceConfidence, .high)
        XCTAssertTrue(state.needsCloserFrame)
    }

    @MainActor
    func testSessionStateProvidesCloseFrameFollowUpsWhenNeeded() {
        let state = SessionState()

        _ = state.startSession()
        state.didReceiveResponse(
            newAnnotations: [],
            text: "Move a little closer so I can inspect it.",
            needsCloserFrame: true
        )

        XCTAssertEqual(
            state.visibleFollowUpPrompts,
            [
                "Move closer to the task",
                "Center the detail in the frame",
                "What should I zoom in on next?"
            ]
        )
    }

    @MainActor
    func testBackendHealthRefreshDecodesProviderState() async {
        let session = makeMockSession { request in
            let response = Self.okResponse(for: request.url ?? URL(string: "https://fixwise.example.com")!)
            return (response, Self.healthPayload)
        }

        let store = BackendConfigurationStore(
            userDefaults: tempUserDefaults(),
            urlSession: session
        )
        store.backendHTTPURLString = "https://fixwise.example.com"

        let health = await store.refreshHealth()

        XCTAssertEqual(health?.displayProviderName, "Gemma Live")
        XCTAssertEqual(health?.effectiveAvailability, "live")
        XCTAssertTrue(health?.isLiveReady ?? false)
        XCTAssertEqual(store.backendHealth?.ai?.model, "gemma-4-vision")
    }

    @MainActor
    func testRestoreSessionBootstrapsGuestWhenNoStoredTokens() async {
        let session = makeMockSession { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/health":
                return (Self.okResponse(for: request.url ?? URL(string: "https://fixwise.example.com")!), Self.healthPayload)
            case "/api/auth/guest":
                return (Self.okResponse(for: request.url ?? URL(string: "https://fixwise.example.com")!), Self.guestAuthPayload)
            default:
                return (Self.okResponse(for: request.url ?? URL(string: "https://fixwise.example.com")!), Data())
            }
        }

        let backend = BackendConfigurationStore(
            userDefaults: tempUserDefaults(),
            urlSession: session
        )
        backend.backendHTTPURLString = "https://fixwise.example.com"

        let authStore = AuthStore(
            keychain: KeychainStore(service: "com.fixwise.ai.tests.\(UUID().uuidString)"),
            urlSession: session
        )

        await authStore.restoreSession(using: backend)

        XCTAssertTrue(authStore.isAuthenticated)
        XCTAssertTrue(authStore.isGuestSession)
        XCTAssertFalse(authStore.canManageProviderKey)
        XCTAssertEqual(authStore.user?.email, "guest@fixwise.local")
    }

    @MainActor
    func testSignedInUserCanManageProviderKeyButGuestCannot() async {
        let session = makeMockSession { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/auth/login":
                return (Self.okResponse(for: request.url ?? URL(string: "https://fixwise.example.com")!), Self.signedInAuthPayload)
            case "/api/auth/guest":
                return (Self.okResponse(for: request.url ?? URL(string: "https://fixwise.example.com")!), Self.guestAuthPayload)
            case "/health":
                return (Self.okResponse(for: request.url ?? URL(string: "https://fixwise.example.com")!), Self.healthPayload)
            default:
                return (Self.okResponse(for: request.url ?? URL(string: "https://fixwise.example.com")!), Data())
            }
        }

        let backend = BackendConfigurationStore(
            userDefaults: tempUserDefaults(),
            urlSession: session
        )
        backend.backendHTTPURLString = "https://fixwise.example.com"

        let authStore = AuthStore(
            keychain: KeychainStore(service: "com.fixwise.ai.tests.\(UUID().uuidString)"),
            urlSession: session
        )

        let didSignIn = await authStore.signIn(
            email: "person@example.com",
            password: "password123",
            using: backend
        )
        XCTAssertTrue(didSignIn)
        XCTAssertFalse(authStore.isGuestSession)
        XCTAssertTrue(authStore.canManageProviderKey)
    }

    @MainActor
    func testGuestBootstrapEndpointCreatesGuestIdentity() async {
        let session = makeMockSession { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/auth/guest":
                return (Self.okResponse(for: request.url ?? URL(string: "https://fixwise.example.com")!), Self.guestAuthPayload)
            default:
                return (Self.okResponse(for: request.url ?? URL(string: "https://fixwise.example.com")!), Data())
            }
        }

        let backend = BackendConfigurationStore(
            userDefaults: tempUserDefaults(),
            urlSession: session
        )
        backend.backendHTTPURLString = "https://fixwise.example.com"

        let authStore = AuthStore(
            keychain: KeychainStore(service: "com.fixwise.ai.tests.\(UUID().uuidString)"),
            urlSession: session
        )

        let didBootstrapGuest = await authStore.bootstrapGuestSession(using: backend)
        XCTAssertTrue(didBootstrapGuest)
        XCTAssertTrue(authStore.isGuestSession)
        XCTAssertEqual(authStore.user?.displayName, "Guest Tester")
    }

    func testSpeechRecognitionErrorPolicyIgnoresCanceledRequestErrors() {
        let canceledRequest = NSError(
            domain: "kLSRErrorDomain",
            code: 301,
            userInfo: [NSLocalizedDescriptionKey: "Recognition request was canceled."]
        )

        XCTAssertTrue(
            SpeechRecognitionErrorPolicy.shouldIgnore(
                canceledRequest,
                shutdownMode: .idle
            )
        )
    }

    func testSpeechRecognitionErrorPolicyIgnoresErrorsWhileRecognizerIsShuttingDown() {
        let interrupted = NSError(
            domain: "kAFAssistantErrorDomain",
            code: 1107,
            userInfo: [NSLocalizedDescriptionKey: "Connection to speech process was interrupted."]
        )

        XCTAssertTrue(
            SpeechRecognitionErrorPolicy.shouldIgnore(
                interrupted,
                shutdownMode: .canceling
            )
        )
        XCTAssertFalse(
            SpeechRecognitionErrorPolicy.shouldIgnore(
                interrupted,
                shutdownMode: .idle
            )
        )
    }

    func testUserProfileDecodesSnakeAndCamelCaseDisplayName() throws {
        let payload = """
        {
          "id": "user-1",
          "email": "person@example.com",
          "display_name": "Snake Name",
          "displayName": "Camel Name",
          "tier": "free",
          "hasApiKey": false,
          "apiKeyMask": null
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AuthStore.UserProfile.self, from: payload)

        XCTAssertEqual(decoded.displayName, "Snake Name")
        XCTAssertEqual(decoded.email, "person@example.com")
        XCTAssertEqual(decoded.tier, "free")
    }

    private static var healthPayload: Data {
        """
        {
          "status": "ok",
          "environment": "production",
          "provider": "gemma",
          "desired_provider": "gemma",
          "live_ready": true,
          "availability": "live",
          "ai": {
            "provider": "gemma",
            "configured_provider": "gemma",
            "live_ready": true,
            "model": "gemma-4-vision",
            "availability": "live"
          }
        }
        """.data(using: .utf8)!
    }

    private static var guestAuthPayload: Data {
        """
        {
          "access_token": "guest-access-token",
          "refresh_token": "guest-refresh-token",
          "user": {
            "id": "guest-user-1",
            "email": "guest@fixwise.local",
            "display_name": "Guest Tester",
            "tier": "guest",
            "is_guest": true,
            "hasApiKey": false,
            "apiKeyMask": null,
            "apiKeyProvider": null
          }
        }
        """.data(using: .utf8)!
    }

    private static var signedInAuthPayload: Data {
        """
        {
          "access_token": "access-token",
          "refresh_token": "refresh-token",
          "user": {
            "id": "user-1",
            "email": "person@example.com",
            "display_name": "Person",
            "tier": "pro",
            "is_guest": false,
            "hasApiKey": true,
            "apiKeyMask": "sk-••••1234",
            "apiKeyProvider": "gemma"
          }
        }
        """.data(using: .utf8)!
    }

    private static func okResponse(for url: URL) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    private func makeMockSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func tempUserDefaults() -> UserDefaults {
        let suiteName = "FixWise.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
