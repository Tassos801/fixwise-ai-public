import Foundation

@MainActor
final class AuthStore: ObservableObject {
    struct SessionTokens: Codable, Equatable {
        let accessToken: String
        let refreshToken: String
    }

    struct UserProfile: Codable, Equatable {
        let id: String
        let email: String
        let displayName: String?
        let tier: String
        let hasApiKey: Bool?
        let apiKeyMask: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case email
            case displayName = "display_name"
            case tier
            case hasApiKey
            case apiKeyMask
        }
    }

    enum Status: Equatable {
        case signedOut
        case restoring
        case authenticating
        case authenticated
        case failed(String)
    }

    @Published private(set) var status: Status = .signedOut
    @Published private(set) var user: UserProfile?
    @Published private(set) var sessionTokens: SessionTokens?
    @Published private(set) var lastErrorMessage: String?

    private let keychain = KeychainStore(service: "com.fixwise.ai.auth")
    private let sessionAccount = "session"
    private var hasAttemptedRestore = false

    var sessionToken: String? {
        sessionTokens?.accessToken
    }

    var isAuthenticated: Bool {
        sessionTokens != nil && user != nil
    }

    func restoreSession(using backendConfiguration: BackendConfigurationStore) async {
        guard !hasAttemptedRestore else { return }
        hasAttemptedRestore = true
        status = .restoring

        guard let storedTokens = try? keychain.load(SessionTokens.self, account: sessionAccount) else {
            clearTransientState()
            status = .signedOut
            return
        }

        sessionTokens = storedTokens

        if let profile = await fetchCurrentUser(using: backendConfiguration, accessToken: storedTokens.accessToken) {
            user = profile
            lastErrorMessage = nil
            status = .authenticated
            return
        }

        if let refreshedTokens = await refreshTokens(using: backendConfiguration, refreshToken: storedTokens.refreshToken) {
            sessionTokens = refreshedTokens
            persist(refreshedTokens)

            if let profile = await fetchCurrentUser(using: backendConfiguration, accessToken: refreshedTokens.accessToken) {
                user = profile
                lastErrorMessage = nil
                status = .authenticated
                return
            }
        }

        clearSession(message: "Your session expired. Sign in again.")
    }

    func signIn(email: String, password: String, using backendConfiguration: BackendConfigurationStore) async -> Bool {
        await authenticate(
            path: "/api/auth/login",
            payload: AuthCredentials(email: email, password: password),
            using: backendConfiguration
        )
    }

    func register(email: String, password: String, displayName: String?, using backendConfiguration: BackendConfigurationStore) async -> Bool {
        await authenticate(
            path: "/api/auth/register",
            payload: RegistrationCredentials(email: email, password: password, displayName: displayName),
            using: backendConfiguration
        )
    }

    func refreshCurrentUser(using backendConfiguration: BackendConfigurationStore) async -> Bool {
        guard let accessToken = sessionTokens?.accessToken else { return false }
        guard let profile = await fetchCurrentUser(using: backendConfiguration, accessToken: accessToken) else {
            return false
        }

        user = profile
        lastErrorMessage = nil
        return true
    }

    func signOut() {
        do {
            try keychain.delete(account: sessionAccount)
        } catch {
            // Clearing local session should still continue even if Keychain removal fails.
        }
        clearSession(message: nil)
    }

    private func authenticate<Request: Encodable>(
        path: String,
        payload: Request,
        using backendConfiguration: BackendConfigurationStore
    ) async -> Bool {
        status = .authenticating
        lastErrorMessage = nil

        do {
            var request = backendConfiguration.request(path: path, method: "POST")
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = try validateHTTPResponse(response, data: data)

            guard (200...299).contains(httpResponse.statusCode) else {
                throw backendError(from: data, statusCode: httpResponse.statusCode)
            }

            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
            let tokens = SessionTokens(
                accessToken: authResponse.accessToken,
                refreshToken: authResponse.refreshToken
            )
            sessionTokens = tokens
            user = authResponse.user
            persist(tokens)
            status = .authenticated
            return true
        } catch {
            let message = error.localizedDescription
            lastErrorMessage = message
            status = .failed(message)
            return false
        }
    }

    private func fetchCurrentUser(
        using backendConfiguration: BackendConfigurationStore,
        accessToken: String
    ) async -> UserProfile? {
        do {
            let request = backendConfiguration.request(path: "/api/auth/me", authToken: accessToken)
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = try validateHTTPResponse(response, data: data)

            guard (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            return try JSONDecoder().decode(UserProfile.self, from: data)
        } catch {
            return nil
        }
    }

    private func refreshTokens(
        using backendConfiguration: BackendConfigurationStore,
        refreshToken: String
    ) async -> SessionTokens? {
        do {
            var request = backendConfiguration.request(path: "/api/auth/refresh", method: "POST")
            request.httpBody = try JSONEncoder().encode(RefreshCredentials(refreshToken: refreshToken))

            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = try validateHTTPResponse(response, data: data)

            guard (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
            return SessionTokens(
                accessToken: authResponse.accessToken,
                refreshToken: authResponse.refreshToken
            )
        } catch {
            return nil
        }
    }

    private func persist(_ tokens: SessionTokens) {
        do {
            try keychain.save(tokens, account: sessionAccount)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func clearSession(message: String?) {
        clearTransientState()
        status = message == nil ? .signedOut : .failed(message ?? "")
        lastErrorMessage = message
    }

    private func clearTransientState() {
        user = nil
        sessionTokens = nil
    }

    private func validateHTTPResponse(_ response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return httpResponse
    }

    private func backendError(from data: Data, statusCode: Int) -> Error {
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = payload["detail"] as? String {
            return NSError(domain: "FixWise.Auth", code: statusCode, userInfo: [
                NSLocalizedDescriptionKey: detail
            ])
        }

        return NSError(domain: "FixWise.Auth", code: statusCode, userInfo: [
            NSLocalizedDescriptionKey: "Request failed with HTTP \(statusCode)."
        ])
    }

    private struct AuthResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let user: UserProfile

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case user
        }
    }

    private struct AuthCredentials: Encodable {
        let email: String
        let password: String
    }

    private struct RegistrationCredentials: Encodable {
        let email: String
        let password: String
        let displayName: String?

        private enum CodingKeys: String, CodingKey {
            case email
            case password
            case displayName = "display_name"
        }
    }

    private struct RefreshCredentials: Encodable {
        let refreshToken: String

        private enum CodingKeys: String, CodingKey {
            case refreshToken = "refresh_token"
        }
    }
}
