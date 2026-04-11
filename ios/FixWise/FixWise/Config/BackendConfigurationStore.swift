import Foundation

@MainActor
final class BackendConfigurationStore: ObservableObject {
    private let userDefaults: UserDefaults

    @Published var backendHTTPURLString: String {
        didSet {
            persist()
        }
    }

    private enum Keys {
        static let backendHTTPURLString = "backendHTTPURLString"
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
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
