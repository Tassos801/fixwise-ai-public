import Foundation

@MainActor
final class BackendConfigurationStore: ObservableObject {
    private let userDefaults: UserDefaults
    private let urlSession: URLSession

    @Published var backendHTTPURLString: String {
        didSet {
            persist()
        }
    }

    @Published private(set) var backendHealth: BackendHealth?

    private enum Keys {
        static let backendHTTPURLString = "backendHTTPURLString"
    }

    init(userDefaults: UserDefaults = .standard, urlSession: URLSession = .shared) {
        self.userDefaults = userDefaults
        self.urlSession = urlSession
        let storedURL = userDefaults.string(forKey: Keys.backendHTTPURLString)
        backendHTTPURLString = storedURL?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? AppConfig.backendHTTPURL.absoluteString
    }

    var backendHTTPURL: URL {
        normalizedURL(from: backendHTTPURLString, fallback: AppConfig.backendHTTPURL)
    }

    var backendWebSocketURL: URL {
        normalizedWebSocketURL(from: backendHTTPURLString)
    }

    var backendWebSocketURLString: String {
        backendWebSocketURL.absoluteString
    }

    var deploymentBadgeText: String? {
        AppConfig.deploymentBadgeText(for: backendHTTPURL)
    }

    var deviceTestingWarning: String? {
#if targetEnvironment(simulator)
        nil
#else
        if AppConfig.isLoopbackHost(backendHTTPURL) || AppConfig.isLoopbackHost(backendWebSocketURL) {
            return "This build still points at localhost. Open Settings and replace the backend URL with a phone-reachable HTTPS endpoint before testing on a physical iPhone."
        }
        return nil
#endif
    }

    func resetToDefaults() {
        backendHTTPURLString = AppConfig.backendHTTPURL.absoluteString
    }

    func request(path: String, method: String = "GET", authToken: String? = nil) -> URLRequest {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authToken {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func refreshHealth() async -> BackendHealth? {
        do {
            let request = request(path: "/health")
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                backendHealth = nil
                return nil
            }

            let decoded = try JSONDecoder().decode(BackendHealth.self, from: data)
            backendHealth = decoded
            return decoded
        } catch {
            backendHealth = nil
            return nil
        }
    }

    func url(for path: String) -> URL {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return backendHTTPURL.appendingPathComponent(trimmedPath)
    }

    private func persist() {
        userDefaults.set(backendHTTPURLString, forKey: Keys.backendHTTPURLString)
    }

    private func normalizedURL(from string: String, fallback: URL) -> URL {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil,
              url.host != nil else {
            return fallback
        }
        return url
    }

    private func normalizedWebSocketURL(from httpURLString: String) -> URL {
        let fallback = AppConfig.backendWebSocketURL
        guard let httpURL = URL(string: httpURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = httpURL.host,
              httpURL.scheme != nil else {
            return fallback
        }

        var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false)
        components?.scheme = httpURL.scheme == "https" ? "wss" : "ws"

        let basePath = httpURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var pathComponents: [String] = []
        if !basePath.isEmpty {
            pathComponents.append(basePath)
        }
        pathComponents.append("ws")
        pathComponents.append("session")
        components?.path = "/" + pathComponents.joined(separator: "/")

        if let url = components?.url, url.host == host {
            return url
        }

        return fallback
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct BackendHealth: Decodable, Equatable {
    let status: String
    let environment: String?
    let provider: String?
    let desiredProvider: String?
    let liveReady: Bool?
    let availability: String?
    let ai: AIStatus?

    struct AIStatus: Decodable, Equatable {
        let provider: String?
        let configuredProvider: String?
        let liveReady: Bool?
        let model: String?
        let availability: String?
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case environment
        case provider
        case desiredProvider = "desiredProvider"
        case desiredProviderSnake = "desired_provider"
        case liveReady
        case liveReadySnake = "live_ready"
        case availability
        case ai
    }

    private enum AIKeys: String, CodingKey {
        case provider
        case configuredProvider = "configuredProvider"
        case configuredProviderSnake = "configured_provider"
        case liveReady
        case liveReadySnake = "live_ready"
        case model
        case availability
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        environment = try container.decodeIfPresent(String.self, forKey: .environment)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        desiredProvider = try container.decodeIfPresent(String.self, forKey: .desiredProvider)
            ?? container.decodeIfPresent(String.self, forKey: .desiredProviderSnake)
        liveReady = try container.decodeIfPresent(Bool.self, forKey: .liveReady)
            ?? container.decodeIfPresent(Bool.self, forKey: .liveReadySnake)
        availability = try container.decodeIfPresent(String.self, forKey: .availability)

        if let aiContainer = try? container.nestedContainer(keyedBy: AIKeys.self, forKey: .ai) {
            ai = AIStatus(
                provider: try aiContainer.decodeIfPresent(String.self, forKey: .provider),
                configuredProvider: try aiContainer.decodeIfPresent(String.self, forKey: .configuredProvider)
                    ?? aiContainer.decodeIfPresent(String.self, forKey: .configuredProviderSnake),
                liveReady: try aiContainer.decodeIfPresent(Bool.self, forKey: .liveReady)
                    ?? aiContainer.decodeIfPresent(Bool.self, forKey: .liveReadySnake),
                model: try aiContainer.decodeIfPresent(String.self, forKey: .model),
                availability: try aiContainer.decodeIfPresent(String.self, forKey: .availability)
            )
        } else {
            ai = nil
        }
    }

    var effectiveProvider: String {
        (ai?.provider ?? provider ?? desiredProvider ?? "unknown").lowercased()
    }

    var configuredProvider: String {
        (ai?.configuredProvider ?? desiredProvider ?? effectiveProvider).lowercased()
    }

    var isLiveReady: Bool {
        ai?.liveReady ?? liveReady ?? (availability?.lowercased() == "live")
    }

    var effectiveAvailability: String {
        (ai?.availability ?? availability ?? "unknown").lowercased()
    }

    var displayProviderName: String {
        switch effectiveProvider {
        case "mock":
            return "Mock Guidance"
        case "openai":
            return isLiveReady ? "OpenAI Live" : "OpenAI"
        case "gemma":
            return isLiveReady ? "Gemma Live" : "Gemma"
        case "unavailable":
            return "Unavailable"
        default:
            return effectiveProvider.capitalized
        }
    }

    func guidanceHint(hasSavedAPIKey: Bool) -> String? {
        if effectiveAvailability == "unavailable" {
            return "Hosted AI is unavailable right now. Try again in a moment or use an advanced override."
        }

        if effectiveProvider == "mock" {
            if hasSavedAPIKey {
                return "A provider key is saved on your account, but this backend is still serving mock guidance right now."
            }
            return "This backend is healthy but still using mock guidance. Sign in and save a provider key to enable live AI."
        }

        if !isLiveReady {
            return "Live AI is not fully configured on this backend yet."
        }

        return nil
    }
}
