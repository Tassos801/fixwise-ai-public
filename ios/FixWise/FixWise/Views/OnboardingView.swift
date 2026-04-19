import AVFoundation
import Speech
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var backendConfiguration: BackendConfigurationStore

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var cameraGranted = false
    @State private var microphoneGranted = false
    @State private var speechGranted = false
    @State private var isRefreshingBackend = false
    @State private var showSignInSheet = false
    @State private var alertItem: AlertItem?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.08, blue: 0.14),
                        Color(red: 0.08, green: 0.14, blue: 0.18),
                        Color.black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        heroSection
                        permissionsSection
                        backendSection
                        identitySection
                        providerSection
                        primerSection
                        enterButton
                        footerNote
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showSignInSheet) {
                SettingsView(allowsDismissal: true)
            }
            .alert(item: $alertItem) { item in
                Alert(
                    title: Text(item.title),
                    message: Text(item.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .task {
                refreshPermissionState()
                _ = await backendConfiguration.refreshHealth()
            }
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(14)
                    .background(
                        LinearGradient(
                            colors: [.orange, .yellow],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("FixWise")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Hosted beta, guest first, voice first.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                }
            }

            Text("We’ll set up permissions, verify the hosted backend, create a guest identity automatically, and get you into a live session with the shortest path possible.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var permissionsSection: some View {
        onboardingCard(
            title: "1. Permissions",
            subtitle: "Camera, microphone, and speech recognition"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                permissionRow(title: "Camera", granted: cameraGranted)
                permissionRow(title: "Microphone", granted: microphoneGranted)
                permissionRow(title: "Speech Recognition", granted: speechGranted)

                if !allPermissionsGranted {
                    Button {
                        requestAllPermissions()
                    } label: {
                        HStack {
                            Image(systemName: "lock.open.fill")
                            Text("Grant Permissions")
                        }
                    }
                    .buttonStyle(PrimaryOnboardingButtonStyle())
                } else {
                    Text("Permissions are ready. You can move on to the hosted beta check.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var backendSection: some View {
        onboardingCard(
            title: "2. Hosted Backend",
            subtitle: "Verify the public Render beta"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if let health = backendConfiguration.backendHealth {
                    statusPill(
                        title: health.displayProviderName,
                        subtitle: backendStatusSubtitle(for: health),
                        tint: health.isLiveReady ? .green : .orange
                    )

                    if let environment = health.environment {
                        detailRow(label: "Environment", value: environment.capitalized)
                    }

                    if let model = health.ai?.model, !model.isEmpty {
                        detailRow(label: "Model", value: model)
                    }

                    if let hint = health.guidanceHint(hasSavedAPIKey: authStore.user?.hasApiKey ?? false) {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    statusPill(
                        title: "Checking hosted backend",
                        subtitle: "We are reaching the Render beta now.",
                        tint: .yellow
                    )
                }

                Button {
                    Task {
                        await refreshBackendStatus()
                    }
                } label: {
                    HStack {
                        if isRefreshingBackend {
                            ProgressView()
                        }
                        Text("Refresh Backend Check")
                    }
                }
                .buttonStyle(SecondaryOnboardingButtonStyle())

                if let warning = backendConfiguration.deviceTestingWarning {
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var identitySection: some View {
        onboardingCard(
            title: "3. Identity",
            subtitle: "Guest first, FixWise account optional"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if authStore.status == .restoring || authStore.status == .authenticating {
                    statusPill(
                        title: "Creating guest identity",
                        subtitle: "Your device is being prepared for a live session.",
                        tint: .yellow
                    )
                } else if let user = authStore.user {
                    if authStore.isGuestSession {
                        statusPill(
                            title: "Guest ready",
                            subtitle: user.displayName ?? "A guest identity is stored on this device.",
                            tint: .green
                        )
                        Text("This is enough to start guided sessions right away. Sign in only if you want synced history, reports, or a saved provider key.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        statusPill(
                            title: "FixWise account ready",
                            subtitle: user.email,
                            tint: .green
                        )
                        Text("Your account will sync history and reports. Guest access still stays available if you sign out.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let message = authStore.lastErrorMessage, !message.isEmpty {
                    statusPill(
                        title: "Guest setup needs another try",
                        subtitle: message,
                        tint: .orange
                    )
                } else {
                    statusPill(
                        title: "Waiting for guest identity",
                        subtitle: "FixWise will create one automatically on launch.",
                        tint: .yellow
                    )
                }

                HStack(spacing: 12) {
                    Button {
                        showSignInSheet = true
                    } label: {
                        Label("Sign In or Create Account", systemImage: "person.crop.circle")
                    }
                    .buttonStyle(SecondaryOnboardingButtonStyle())

                    Button {
                        if canEnterApp {
                            hasCompletedOnboarding = true
                        } else {
                            alertItem = AlertItem(
                                title: "Guest Setup Pending",
                                message: "FixWise needs permissions, a reachable backend, and a guest identity before you can continue."
                            )
                        }
                    } label: {
                        Text("Continue as Guest")
                    }
                    .buttonStyle(PrimaryOnboardingButtonStyle())
                }
            }
        }
    }

    private var providerSection: some View {
        onboardingCard(
            title: "4. Optional Provider Key",
            subtitle: "Only for signed-in accounts"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if authStore.canManageProviderKey {
                    Text("If you want the hosted beta to use your own provider key, open Settings after you enter the app. Guests do not need a key.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        showSignInSheet = true
                    } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(SecondaryOnboardingButtonStyle())
                } else {
                    Text("Guests can start right away. Provider keys are optional and only appear after you sign in to a FixWise account.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var primerSection: some View {
        onboardingCard(
            title: "How to ask",
            subtitle: "Keep it short and natural"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                primerChip(text: "What am I looking at?")
                primerChip(text: "What should I do next?")
                primerChip(text: "Is anything unsafe?")

                Text("The app will stay in the conversation with you after each answer, so you can keep asking follow-up questions without starting over.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var enterButton: some View {
        Button {
            hasCompletedOnboarding = true
        } label: {
            HStack {
                Image(systemName: "arrow.right.circle.fill")
                Text("Enter FixWise")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryOnboardingButtonStyle())
        .disabled(!canEnterApp)
        .opacity(canEnterApp ? 1 : 0.55)
        .padding(.top, 6)
    }

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You can change the backend later in Settings > Advanced / Developer if you are testing an override.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))

            if let warning = backendConfiguration.deviceTestingWarning {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.top, 6)
    }

    private var canEnterApp: Bool {
        allPermissionsGranted && backendConfiguration.backendHealth != nil && authStore.isAuthenticated
    }

    private var allPermissionsGranted: Bool {
        cameraGranted && microphoneGranted && speechGranted
    }

    private func onboardingCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
            }

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func permissionRow(title: String, granted: Bool) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.seal.fill" : "circle")
                .foregroundStyle(granted ? .green : .white.opacity(0.45))
            Text(title)
                .foregroundStyle(.white)
            Spacer()
            Text(granted ? "Ready" : "Needed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(granted ? .green : .white.opacity(0.55))
        }
    }

    private func statusPill(title: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.white.opacity(0.72))
            Spacer()
            Text(value)
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }

    private func primerChip(text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.08), in: Capsule())
    }

    private func refreshPermissionState() {
        cameraGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    private func requestAllPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.cameraGranted = granted
            }
        }

        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.microphoneGranted = granted
            }
        }

        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                self.speechGranted = status == .authorized
            }
        }
    }

    private func refreshBackendStatus() async {
        isRefreshingBackend = true
        defer { isRefreshingBackend = false }
        _ = await backendConfiguration.refreshHealth()
    }

    private func backendStatusSubtitle(for health: BackendHealth) -> String {
        switch health.effectiveAvailability {
        case "live":
            return "Live provider is ready."
        case "degraded":
            return "Hosted beta is available, but live AI is not fully ready."
        case "unavailable":
            return "Hosted AI is currently unavailable."
        default:
            return health.isLiveReady ? "Live provider is ready." : "Hosted beta is reachable."
        }
    }
}

private struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct PrimaryOnboardingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(
                LinearGradient(
                    colors: [.orange, .yellow],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
    }
}

private struct SecondaryOnboardingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
    }
}
