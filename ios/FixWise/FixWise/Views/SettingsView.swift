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
    @State private var displayName = ""
    @State private var apiKeyInput = ""
    @State private var isTestingConnection = false
    @State private var isSavingKey = false
    @State private var isRemovingKey = false
    @State private var backendHealth: BackendHealth?
    @State private var alertItem: AlertItem?

    init(allowsDismissal: Bool = true) {
        self.allowsDismissal = allowsDismissal
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
                backendSection

                if authStore.isAuthenticated {
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

                Button("Sign Out", role: .destructive) {
                    authStore.signOut()
                }
            } else {
                Picker("Mode", selection: $authMode) {
                    ForEach(AuthMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
                    .textContentType(.password)

                if authMode == .register {
                    TextField("Display name (optional)", text: $displayName)
                        .textInputAutocapitalization(.words)
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
                                displayName: displayName.nilIfEmpty,
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
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Sign in before starting a live session so BYOK, history, and reports stay attached to your account.")
        }
    }

    private var backendSection: some View {
        Section {
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

            if let backendHealth {
                backendHealthSummary(backendHealth)
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

            Button("Reset to Default") {
                backendConfiguration.resetToDefaults()
            }
        } header: {
            Text("Backend")
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
                SecureField("sk-...", text: $apiKeyInput)
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
            Text("OpenAI API Key (BYOK)")
        } footer: {
            Text("Your API key is encrypted by the backend and is never stored on-device.")
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

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func testConnection() async {
        isTestingConnection = true
        defer { isTestingConnection = false }

        do {
            let (data, response) = try await URLSession.shared.data(for: backendConfiguration.request(path: "/health"))
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            if httpResponse.statusCode == 200 {
                let decodedHealth = try? JSONDecoder().decode(BackendHealth.self, from: data)
                backendHealth = decodedHealth
                alertItem = AlertItem(
                    title: "Connected",
                    message: connectionSuccessMessage(for: decodedHealth)
                )
            } else {
                backendHealth = nil
                alertItem = AlertItem(
                    title: "Connection Failed",
                    message: "Server returned HTTP \(httpResponse.statusCode)."
                )
            }
        } catch {
            backendHealth = nil
            alertItem = AlertItem(title: "Connection Failed", message: error.localizedDescription)
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
}

private struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct BackendHealth: Decodable {
    let status: String
    let environment: String?
    let provider: String?
    let liveReady: Bool?
    let ai: AIStatus?

    struct AIStatus: Decodable {
        let provider: String?
        let liveReady: Bool?
        let model: String?
    }

    var effectiveProvider: String {
        (ai?.provider ?? provider ?? "unknown").lowercased()
    }

    var isLiveReady: Bool {
        ai?.liveReady ?? liveReady ?? false
    }

    var displayProviderName: String {
        switch effectiveProvider {
        case "mock":
            return "Mock Guidance"
        case "openai":
            return isLiveReady ? "OpenAI Live" : "OpenAI"
        case "unavailable":
            return "Unavailable"
        default:
            return effectiveProvider.capitalized
        }
    }

    func guidanceHint(hasSavedAPIKey: Bool) -> String? {
        if effectiveProvider == "mock" {
            if hasSavedAPIKey {
                return "A BYOK key is saved on your account, but this backend is still serving mock guidance right now."
            }
            return "This backend is healthy but still using mock guidance. Sign in and save a BYOK OpenAI key to enable live AI."
        }

        if !isLiveReady {
            return "Live AI is not fully configured on this backend yet."
        }

        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview {
    SettingsView()
        .environmentObject(AuthStore())
        .environmentObject(BackendConfigurationStore())
}
