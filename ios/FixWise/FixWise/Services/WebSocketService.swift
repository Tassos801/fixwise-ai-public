import Combine
import Foundation

/// Manages the WebSocket connection to the FixWise backend.
/// Handles connection lifecycle, message serialization, and reconnection logic.
final class WebSocketService: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    struct Config {
        var serverURL: URL
        var maxReconnectAttempts: Int = 10
        var initialReconnectDelay: TimeInterval = 1.0
        var maxReconnectDelay: TimeInterval = 30.0
    }

    enum OutgoingMessage: Encodable {
        case frame(FrameMessage)
        case prompt(PromptMessage)
        case endSession(sessionId: String)

        struct FrameMessage: Encodable {
            let type = "frame"
            let sessionId: String
            let timestamp: TimeInterval
            let frame: String
            let frameMetadata: FrameMetadata
        }

        struct PromptMessage: Encodable {
            let type = "prompt"
            let sessionId: String
            let timestamp: TimeInterval
            let text: String
        }

        struct FrameMetadata: Encodable {
            let width: Int
            let height: Int
            let sceneDelta: Float
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .frame(let message):
                try message.encode(to: encoder)
            case .prompt(let message):
                try message.encode(to: encoder)
            case .endSession(let sessionId):
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode("end_session", forKey: .type)
                try container.encode(sessionId, forKey: .sessionId)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case sessionId
        }
    }

    struct IncomingResponse: Decodable {
        let type: String
        let sessionId: String?
        let text: String?
        let annotations: [AnnotationData]?
        let stepNumber: Int?
        let safetyWarning: String?
        let reason: String?
        let recommendation: String?
        let message: String?
    }

    struct AnnotationData: Decodable {
        let type: String
        let label: String
        let x: Float?
        let y: Float?
        let radius: Float?
        let color: String?
        let from: Point2D?
        let to: Point2D?

        struct Point2D: Decodable {
            let x: Float
            let y: Float
        }
    }

    let responsePublisher = PassthroughSubject<IncomingResponse, Never>()

    private var config: Config
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var authToken: String?
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var shouldReconnect = false
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(config: Config) {
        self.config = config
    }

    func updateServerURL(_ serverURL: URL) {
        guard config.serverURL != serverURL else { return }

        let shouldReconnect = connectionState != .disconnected
        let currentAuthToken = authToken

        reconnectWorkItem?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession = nil
        config.serverURL = serverURL
        connectionState = .disconnected

        guard shouldReconnect else { return }
        connect(authToken: currentAuthToken)
    }

    var canSendInteractiveMessages: Bool {
        connectionState.isConnected && webSocketTask != nil
    }

    func connect(authToken: String? = nil) {
        self.authToken = authToken
        shouldReconnect = true
        reconnectWorkItem?.cancel()
        connectionState = .connecting

        let request = URLRequest(url: configuredURL(authToken: authToken))

        let session = URLSession(configuration: .default)
        urlSession = session

        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        performHandshake()
    }

    func disconnect() {
        shouldReconnect = false
        reconnectWorkItem?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession = nil
        connectionState = .disconnected
    }

    @discardableResult
    func send(_ message: OutgoingMessage) -> Bool {
        guard canSendInteractiveMessages else { return false }

        do {
            let payload = try encode(message)
            let string = String(decoding: payload, as: UTF8.self)
            webSocketTask?.send(.string(string)) { [weak self] error in
                if let error {
                    self?.handleDisconnect(error: error)
                }
            }
            return true
        } catch {
            print("[WebSocket] Encoding error: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func sendFrame(_ encoded: CameraService.EncodedFrame, sessionId: String) -> Bool {
        let message = OutgoingMessage.frame(
            .init(
                sessionId: sessionId,
                timestamp: encoded.timestamp,
                frame: encoded.base64,
                frameMetadata: .init(
                    width: encoded.width,
                    height: encoded.height,
                    sceneDelta: encoded.sceneDelta
                )
            )
        )
        return send(message)
    }

    @discardableResult
    func sendPrompt(_ prompt: String, sessionId: String) -> Bool {
        let message = OutgoingMessage.prompt(
            .init(
                sessionId: sessionId,
                timestamp: Date().timeIntervalSince1970,
                text: prompt
            )
        )
        return send(message)
    }

    @discardableResult
    func sendEndSession(sessionId: String) -> Bool {
        send(.endSession(sessionId: sessionId))
    }

    func encode(_ message: OutgoingMessage) throws -> Data {
        try encoder.encode(message)
    }

    func decode(_ data: Data) throws -> IncomingResponse {
        try decoder.decode(IncomingResponse.self, from: data)
    }

    private func performHandshake() {
        webSocketTask?.sendPing { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.handleDisconnect(error: error)
                    return
                }

                self.connectionState = .connected
                self.reconnectAttempt = 0
                self.listenForMessages()
            }
        }
    }

    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.listenForMessages()
            case .failure(let error):
                self.handleDisconnect(error: error)
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let payload):
            data = payload
        case .string(let payload):
            guard let encoded = payload.data(using: .utf8) else { return }
            data = encoded
        @unknown default:
            return
        }

        do {
            let response = try decode(data)
            DispatchQueue.main.async {
                self.responsePublisher.send(response)
            }
        } catch {
            print("[WebSocket] Decode error: \(error.localizedDescription)")
        }
    }

    private func handleDisconnect(error: Error? = nil) {
        if !shouldReconnect {
            DispatchQueue.main.async {
                self.connectionState = .disconnected
            }
            return
        }

        guard reconnectAttempt < config.maxReconnectAttempts else {
            DispatchQueue.main.async {
                self.connectionState = .disconnected
            }
            if let error {
                print("[WebSocket] Max reconnection attempts reached: \(error.localizedDescription)")
            }
            return
        }

        reconnectAttempt += 1
        let delay = min(
            config.initialReconnectDelay * pow(2.0, Double(reconnectAttempt - 1)),
            config.maxReconnectDelay
        )

        DispatchQueue.main.async {
            self.connectionState = .reconnecting(attempt: self.reconnectAttempt)
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.connect(authToken: self.authToken)
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func configuredURL(authToken: String?) -> URL {
        guard let authToken, !authToken.isEmpty,
              var components = URLComponents(url: config.serverURL, resolvingAgainstBaseURL: false) else {
            return config.serverURL
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "token" }
        queryItems.append(URLQueryItem(name: "token", value: authToken))
        components.queryItems = queryItems
        return components.url ?? config.serverURL
    }
}
