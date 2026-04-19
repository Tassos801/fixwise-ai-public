import Foundation

enum AppConfig {
    static let defaultBackendHTTPURLString = "https://fixwise-backend.onrender.com"
    static let defaultBackendWebSocketURLString = "wss://fixwise-backend.onrender.com/ws/session"
    static let hostedBetaHost = "fixwise-backend.onrender.com"

    static var backendHTTPURL: URL {
        url(for: "FIXWISE_BACKEND_HTTP_URL", fallback: defaultBackendHTTPURLString)
    }

    static var backendWebSocketURL: URL {
        url(for: "FIXWISE_BACKEND_WS_URL", fallback: defaultBackendWebSocketURLString)
    }

    static var deviceTestingWarning: String? {
#if targetEnvironment(simulator)
        return nil
#else
        if isLoopbackHost(backendHTTPURL) || isLoopbackHost(backendWebSocketURL) {
            return "This build is using a localhost override. Open Settings > Advanced / Developer and replace it with a phone-reachable HTTPS endpoint before testing on a physical iPhone."
        }
        return nil
#endif
    }

    private static func url(for key: String, fallback: String) -> URL {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           let url = URL(string: value) {
            return url
        }

        guard let fallbackURL = URL(string: fallback) else {
            preconditionFailure("Invalid fallback URL for \(key)")
        }
        return fallbackURL
    }

    static func isLoopbackHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }

    static func deploymentBadgeText(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == hostedBetaHost {
            return "Hosted Beta"
        }
        return nil
    }
}
