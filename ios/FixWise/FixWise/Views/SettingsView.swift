import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var backendConfiguration: BackendConfigurationStore

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true

    private let allowsDismissal: Bool

    @State private var authMode: AuthMode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var apiKeyInput = ""
    @State private var isTestingConnection = false
    @State private var isSavingKey = false
    @State private var isRemovingKey = false
    @State private var alertItem: AlertItem?
    @State private var showAdvancedBackendSection = false

    init(allowsDismissal: Bool = true) {
        self.allowsDismissal = allowsDismissal
        _authMode = State(initialValue: .register)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let warning = backendConfiguration.deviceTestingWarning {
                    Section("Phone Testing") {
                        Text(warning)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                accountSection
                aiProviderNoticeSection
                advancedBackendSection

                if authStore.canManageProviderKey {
                    apiKeySection
                }

                aboutSection
            }
            .navigationTitle(allowsDismissal ? "Settings" : "Sign In & Configure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if allowsDismissal {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .alert(item: $alertItem) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var accountSection: some View {
        Section {
            if authStore.isAuthenticated, let user = authStore.user {
                if authStore.isGuestSession {
                    LabeledContent("Mode", value: "Guest")

                    if let displayName = user.displayName, !displayName.isEmpty {
                        LabeledContent("Guest Name", value: displayName)
                    }

                    Text("Guest access is active on this device. Create a FixWise account only if you want synced history, reports, or a saved provider key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Email", value: user.email)
                    LabeledContent("Plan", value: user.tier.capitalized)

                    if let displayName = user.displayName, !displayName.isEmpty {
                        LabeledContent("Display Name", value: displayName)
                    }

                    Button("Refresh Account") {
                        Task {
                            let refreshed = await authStore.refreshCurrentUser(using: backendConfiguration)
                            if !refreshed, let message = authStore.lastErrorMessage {
                                alertItem = AlertItem(title: "Refresh Failed", message: message)
                            }
                        }
                    }
                }

                Button(authStore.isGuestSession ? "Return to Guest" : "Sign Out", role: .destructive) {
                    Task {
                        if authStore.isGuestSession {
                            authStore.signOut()
                        } else {
                            await authStore.signOutAndContinueAsGuest(using: backendConfiguration)
                        }
                    }
                }
            } else {
                Text(accountIntroCopy)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField("Email address", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField(passwordFieldTitle, text: $password)
                    .textContentType(.password)

                if let hint = authFormHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let message = authStore.lastErrorMessage, !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    Task {
                        let success: Bool
                        switch authMode {
                        case .signIn:
                            success = await authStore.signIn(
                                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                password: password,
                                using: backendConfiguration
                            )
                        case .register:
                            success = await authStore.register(
                                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                password: password,
                                using: backendConfiguration
                            )
                        }

                        if success {
                            password = ""
                            apiKeyInput = ""
                            if allowsDismissal {
                                dismiss()
                            }
                        }
                    }
                } label: {
                    HStack {
                        if authStore.status == .authenticating {
                            ProgressView()
                        }
                        Text(authMode.buttonTitle)
                    }
                }
                .disabled(!canSubmitAuthForm)

                Button(authMode.togglePrompt) {
                    authMode = authMode.toggled
                    authStore.clearErrorMessage()
                }
                .font(.footnote.weight(.semibold))
            }
        } header: {
            Text(allowsDismissal ? "FixWise Account (Optional)" : "FixWise Account")
        } footer: {
            Text("Guest access is created automatically on first launch. Create a FixWise account only if you want synced history, reports, and an encrypted provider key.")
        }
    }

    private var aiProviderNoticeSection: some View {
        Section("AI Providers") {
            Text("Third-party model-provider account sign-in is not available in FixWise. Sign in with your FixWise account first, then add a provider API key if you want live hosted AI.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("This backend can be configured for providers like OpenAI or Gemma. Guests can use the hosted provider without adding a key.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var advancedBackendSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvancedBackendSection) {
                VStack(alignment: .leading, spacing: 14) {
                    if let deploymentBadgeText = backendConfiguration.deploymentBadgeText {
                        HStack {
                            Text("Deployment")
                            Spacer()
                            Text(deploymentBadgeText)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.15), in: Capsule())
                        }
                    }

                    if let backendHealth = backendConfiguration.backendHealth {
                        backendHealthSummary(backendHealth)
                    } else {
                        Text("Tap Test Connection to verify the hosted backend and live provider state.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    TextField("https://your-backend.example.com", text: $backendConfiguration.backendHTTPURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    LabeledContent("WebSocket") {
                        Text(backendConfiguration.backendWebSocketURLString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }

                    Button {
                        Task {
                            await testConnection()
                        }
                    } label: {
                        HStack {
                            if isTestingConnection {
                                ProgressView()
                            }
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTestingConnection)

                    Button("Reset to Hosted Default") {
                        backendConfiguration.resetToDefaults()
                    }
                }
                .padding(.vertical, 8)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Advanced / Developer")
                    Text("Backend URL, connection checks, and local override testing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Use a public HTTPS backend URL for device testing. The live session will derive its WSS endpoint automatically.")
        }
    }

    private func backendHealthSummary(_ health: BackendHealth) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Backend Status", value: health.status.capitalized)
            LabeledContent("AI Mode", value: health.displayProviderName)

            if let environment = health.environment {
                LabeledContent("Environment", value: environment.capitalized)
            }

            if let model = health.ai?.model, !model.isEmpty {
                LabeledContent("Model", value: model)
            }

            if let hint = health.guidanceHint(hasSavedAPIKey: authStore.user?.hasApiKey ?? false) {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var apiKeySection: some View {
        Section {
            if let mask = authStore.user?.apiKeyMask, !mask.isEmpty {
                LabeledContent("Saved Key", value: mask)

                Button {
                    Task {
                        await removeAPIKey()
                    }
                } label: {
                    HStack {
                        if isRemovingKey {
                            ProgressView()
                        }
                        Text("Remove Key")
                    }
                }
                .disabled(isRemovingKey)
            } else {
                SecureField(apiKeyPlaceholder, text: $apiKeyInput)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button {
                    Task {
                        await validateAndSaveAPIKey()
                    }
                } label: {
                    HStack {
                        if isSavingKey {
                            ProgressView()
                        }
                        Text("Validate & Save")
                    }
                }
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSavingKey)
            }
        } header: {
            Text(apiKeySectionTitle)
        } footer: {
            Text("This is for provider API access only. Your key is encrypted by the backend and is never stored on-device.")
        }
    }

    private var apiKeySectionTitle: String {
        switch backendConfiguration.backendHealth?.configuredProvider {
        case "gemma":
            return "Gemma API Key (Google AI Studio)"
        case "openai":
            return "OpenAI API Key"
        default:
            return "AI Provider API Key (Optional BYOK)"
        }
    }

    private var apiKeyPlaceholder: String {
        switch backendConfiguration.backendHealth?.configuredProvider {
        case "gemma":
            return "AIza..."
        case "openai":
            return "sk-..."
        default:
            return "Paste provider key"
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: appVersion)

            Button("Reset Onboarding") {
                hasCompletedOnboarding = false
                alertItem = AlertItem(
                    title: "Onboarding Reset",
                    message: "The onboarding flow will appear the next time you launch the app."
                )
            }
        } header: {
            Text("About")
        }
    }

    private var canSubmitAuthForm: Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if authMode == .register {
            return !trimmedEmail.isEmpty && password.count >= 8
        }
        return !trimmedEmail.isEmpty && !password.isEmpty
    }

    private var passwordFieldTitle: String {
        authMode == .register ? "Password (8+ characters)" : "Password"
    }

    private var authFormHint: String? {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedEmail.isEmpty {
            return authMode == .register
                ? "Enter your email and choose a password to create a FixWise account."
                : "Enter your email and password to sign in."
        }

        if authMode == .register {
            if password.count < 8 {
                return "New accounts need at least 8 characters for the password."
            }

            return "No display name is required. We will infer a friendly name from your email if needed."
        }

        if password.isEmpty {
            return "Use the password for your existing FixWise account."
        }

        return nil
    }

    private var accountIntroCopy: String {
        switch authMode {
        case .register:
            return "Create a FixWise account with just your email and password. Guest access is already available on this device."
        case .signIn:
            return "Sign in with the email and password from your existing FixWise account."
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func testConnection() async {
        isTestingConnection = true
        defer { isTestingConnection = false }

        if let decodedHealth = await backendConfiguration.refreshHealth() {
            alertItem = AlertItem(
                title: "Connected",
                message: connectionSuccessMessage(for: decodedHealth)
            )
        } else {
            alertItem = AlertItem(
                title: "Connection Failed",
                message: "The backend could not be reached or did not return healthy status."
            )
        }
    }

    private func connectionSuccessMessage(for health: BackendHealth?) -> String {
        guard let health else {
            return "Backend is reachable and healthy."
        }

        var lines = [
            "Backend is reachable and healthy.",
            "AI Mode: \(health.displayProviderName)"
        ]

        if let environment = health.environment {
            lines.append("Environment: \(environment.capitalized)")
        }

        if let hint = health.guidanceHint(hasSavedAPIKey: authStore.user?.hasApiKey ?? false) {
            lines.append(hint)
        }

        return lines.joined(separator: "\n")
    }

    private func validateAndSaveAPIKey() async {
        guard let authToken = authStore.sessionToken else {
            alertItem = AlertItem(title: "Sign In Required", message: "Sign in before saving a BYOK key.")
            return
        }

        let trimmedKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        isSavingKey = true
        defer { isSavingKey = false }

        do {
            var request = backendConfiguration.request(
                path: "/api/settings/api-key",
                method: "PUT",
                authToken: authToken
            )
            request.httpBody = try JSONSerialization.data(
                withJSONObject: ["apiKey": trimmedKey],
                options: []
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw backendError(from: data, statusCode: httpResponse.statusCode)
            }

            apiKeyInput = ""
            _ = await authStore.refreshCurrentUser(using: backendConfiguration)
            alertItem = AlertItem(title: "Saved", message: "Your API key has been validated and saved.")
        } catch {
            alertItem = AlertItem(title: "Validation Failed", message: error.localizedDescription)
        }
    }

    private func removeAPIKey() async {
        guard let authToken = authStore.sessionToken else {
            alertItem = AlertItem(title: "Sign In Required", message: "Sign in before removing a BYOK key.")
            return
        }

        isRemovingKey = true
        defer { isRemovingKey = false }

        do {
            let request = backendConfiguration.request(
                path: "/api/settings/api-key",
                method: "DELETE",
                authToken: authToken
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw backendError(from: data, statusCode: httpResponse.statusCode)
            }

            _ = await authStore.refreshCurrentUser(using: backendConfiguration)
            alertItem = AlertItem(title: "Removed", message: "Your API key has been removed.")
        } catch {
            alertItem = AlertItem(title: "Remove Failed", message: error.localizedDescription)
        }
    }

    private func backendError(from data: Data, statusCode: Int) -> Error {
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = payload["detail"] as? String {
            return NSError(domain: "FixWise.Settings", code: statusCode, userInfo: [
                NSLocalizedDescriptionKey: detail
            ])
        }

        return NSError(domain: "FixWise.Settings", code: statusCode, userInfo: [
            NSLocalizedDescriptionKey: "Request failed with HTTP \(statusCode)."
        ])
    }
}

private enum AuthMode: CaseIterable {
    case signIn
    case register

    var title: String {
        switch self {
        case .signIn:
            return "Sign In"
        case .register:
            return "Register"
        }
    }

    var buttonTitle: String {
        switch self {
        case .signIn:
            return "Sign In"
        case .register:
            return "Create Account"
        }
    }

    var togglePrompt: String {
        switch self {
        case .signIn:
            return "Need a new account? Create one"
        case .register:
            return "Already have an account? Sign in"
        }
    }

    var toggled: AuthMode {
        switch self {
        case .signIn:
            return .register
        case .register:
            return .signIn
        }
    }
}

private struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

#Preview {
    SettingsView()
        .environmentObject(AuthStore())
        .environmentObject(BackendConfigurationStore())
}
