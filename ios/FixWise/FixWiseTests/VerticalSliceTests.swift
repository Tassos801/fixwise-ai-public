import Foundation
import XCTest
@testable import FixWise

final class VerticalSliceTests: XCTestCase {
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
                text: "What should I do next?"
            )
        )

        let data = try service.encode(message)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["type"] as? String, "prompt")
        XCTAssertEqual(json["sessionId"] as? String, "session-1")
        XCTAssertEqual(json["text"] as? String, "What should I do next?")
    }

    func testPromptSendReturnsFalseWhileDisconnected() {
        let service = WebSocketService(
            config: .init(serverURL: URL(string: "ws://localhost:8000/ws/session")!)
        )

        XCTAssertFalse(service.sendPrompt("What should I do next?", sessionId: "session-1"))
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
          "safetyWarning": null
        }
        """.data(using: .utf8)!

        let decoded = try service.decode(payload)

        XCTAssertEqual(decoded.type, "response")
        XCTAssertEqual(decoded.sessionId, "session-1")
        XCTAssertEqual(decoded.annotations?.first?.label, "Valve")
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

        XCTAssertEqual(text, "", "Internal frame messages should be filtered out entirely")
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
}
