import Foundation

@MainActor
final class AuthStore: ObservableObject {
    struct SessionTokens: Codable, Equatable {
        let accessToken: String
        let refreshToken: String
    }

    struct UserProfile: Decodable, Equatable {
        let id: String
        let email: String
        let displayName: String?
        let tier: String
        let isGuest: Bool?
        let hasApiKey: Bool?
        let apiKeyMask: String?
        let apiKeyProvider: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case email
            case displayNameSnake = "display_name"
            case displayNameCamel = "displayName"
            case tier
            case isGuest = "is_guest"
            case isGuestCamel = "isGuest"
            case hasApiKey
            case apiKeyMask
            case apiKeyProvider
        }

        init(
            id: String,
            email: String,
            displayName: String?,
            tier: String,
            isGuest: Bool?,
            hasApiKey: Bool?,
            apiKeyMask: String?,
            apiKeyProvider: String?
        ) {
            self.id = id
            self.email = email
            self.displayName = displayName
            self.tier = tier
            self.isGuest = isGuest
            self.hasApiKey = hasApiKey
            self.apiKeyMask = apiKeyMask
            self.apiKeyProvider = apiKeyProvider
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            email = try container.decode(String.self, forKey: .email)
            displayName = try container.decodeIfPresent(String.self, forKey: .displayNameSnake)
                ?? container.decodeIfPresent(String.self, forKey: .displayNameCamel)
            tier = try container.decode(String.self, forKey: .tier)
            isGuest = try container.decodeIfPresent(Bool.self, forKey: .isGuest)
                ?? container.decodeIfPresent(Bool.self, forKey: .isGuestCamel)
            hasApiKey = try container.decodeIfPresent(Bool.self, forKey: .hasApiKey)
            apiKeyMask = try container.decodeIfPresent(String.self, forKey: .apiKeyMask)
            apiKeyProvider = try container.decodeIfPresent(String.self, forKey: .apiKeyProvider)
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

    private let keychain: KeychainStore
    private let urlSession: URLSession
    private let sessionAccount = "session"
    private var hasAttemptedRestore = false

    init(
        keychain: KeychainStore = KeychainStore(service: "com.fixwise.ai.auth"),
        urlSession: URLSession = .shared
    ) {
        self.keychain = keychain
        self.urlSession = urlSession
    }

    var sessionToken: String? {
        sessionTokens?.accessToken
    }

    /// Returns a token suitable for an immediate WebSocket connect, preferring the in-memory
    /// session token but falling back to whatever is in the Keychain so callers don't have
    /// to wait for `restoreSession` to finish its network round-trip.
    func tokenForOptimisticConnect() -> String? {
        if let token = sessionTokens?.accessToken {
            return token
        }
        if let stored = try? keychain.load(SessionTokens.self, account: sessionAccount) {
            sessionTokens = stored
            return stored.accessToken
        }
        return nil
    }

    var isAuthenticated: Bool {
        sessionTokens != nil && user != nil
    }

    var isGuestSession: Bool {
        guard let user else { return false }
        return user.isGuest == true || user.tier.lowercased() == "guest"
    }

    var canManageProviderKey: Bool {
        isAuthenticated && !isGuestSession
    }

    func restoreSession(using backendConfiguration: BackendConfigurationStore) async {
        guard !hasAttemptedRestore else { return }
        hasAttemptedRestore = true
        status = .restoring

        guard let storedTokens = try? keychain.load(SessionTokens.self, account: sessionAccount) else {
            clearTransientState()
            if await bootstrapGuestSession(using: backendConfiguration) {
                return
            }

            clearSession(message: lastErrorMessage ?? "FixWise could not create a guest session yet. Try again or sign in.")
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

        clearTransientState()

        if await bootstrapGuestSession(using: backendConfiguration) {
            return
        }

        clearSession(message: lastErrorMessage ?? "FixWise could not create a guest session yet. Try again or sign in.")
    }

    func signIn(email: String, password: String, using backendConfiguration: BackendConfigurationStore) async -> Bool {
        let trimmedEmail = normalizedEmail(email)
        guard validateSignIn(email: trimmedEmail, password: password) else {
            return false
        }

        return await authenticate(
            path: "/api/auth/login",
            payload: AuthCredentials(email: trimmedEmail, password: password),
            using: backendConfiguration
        )
    }

    func register(email: String, password: String, using backendConfiguration: BackendConfigurationStore) async -> Bool {
        let trimmedEmail = normalizedEmail(email)
        guard validateRegistration(email: trimmedEmail, password: password) else {
            return false
        }

        return await authenticate(
            path: "/api/auth/register",
            payload: RegistrationCredentials(
                email: trimmedEmail,
                password: password,
                displayName: Self.displayNameSuggestion(for: trimmedEmail)
            ),
            using: backendConfiguration
        )
    }

    func bootstrapGuestSession(using backendConfiguration: BackendConfigurationStore) async -> Bool {
        if isGuestSession {
            status = .authenticated
            lastErrorMessage = nil
            return true
        }

        status = .authenticating
        lastErrorMessage = nil

        do {
            var request = backendConfiguration.request(path: "/api/auth/guest", method: "POST")
            request.httpBody = try JSONEncoder().encode(GuestBootstrapRequest())

            let (data, response) = try await urlSession.data(for: request)
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

    func signOutAndContinueAsGuest(using backendConfiguration: BackendConfigurationStore) async {
        signOut()
        _ = await bootstrapGuestSession(using: backendConfiguration)
    }

    func clearErrorMessage() {
        if case .failed = status {
            status = .signedOut
        }
        lastErrorMessage = nil
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

            let (data, response) = try await urlSession.data(for: request)
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
            let (data, response) = try await urlSession.data(for: request)
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

            let (data, response) = try await urlSession.data(for: request)
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

    private func validateSignIn(email: String, password: String) -> Bool {
        guard !email.isEmpty else {
            return failValidation("Enter your email address to sign in.")
        }

        guard !password.isEmpty else {
            return failValidation("Enter your password to sign in.")
        }

        return true
    }

    private func validateRegistration(email: String, password: String) -> Bool {
        guard !email.isEmpty else {
            return failValidation("Enter your email address to create an account.")
        }

        guard password.count >= 8 else {
            return failValidation("Create a password with at least 8 characters.")
        }

        return true
    }

    private func failValidation(_ message: String) -> Bool {
        lastErrorMessage = message
        status = .failed(message)
        return false
    }

    private func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func displayNameSuggestion(for email: String) -> String? {
        guard let localPart = email.split(separator: "@").first else {
            return nil
        }

        let cleaned = localPart
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return nil }

        return cleaned
            .split(separator: " ")
            .map { word in
                let lowercased = word.lowercased()
                let first = String(lowercased.prefix(1)).uppercased()
                let rest = String(lowercased.dropFirst())
                return first + rest
            }
            .joined(separator: " ")
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

    private struct GuestBootstrapRequest: Encodable {}
}
