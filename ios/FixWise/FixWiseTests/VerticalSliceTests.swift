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

    func testLoopbackHostDetectionRecognizesLocalEndpoints() {
        XCTAssertTrue(AppConfig.isLoopbackHost(URL(string: "http://127.0.0.1:8000")!))
        XCTAssertTrue(AppConfig.isLoopbackHost(URL(string: "ws://localhost:8000/ws/session")!))
        XCTAssertFalse(AppConfig.isLoopbackHost(URL(string: "https://api.fixwise.app")!))
    }
}
