import SwiftUI

@main
struct FixWiseApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @StateObject private var backendConfiguration: BackendConfigurationStore
    @StateObject private var authStore: AuthStore
    @StateObject private var webSocketService: WebSocketService

    init() {
        let backendConfiguration = BackendConfigurationStore()
        _backendConfiguration = StateObject(wrappedValue: backendConfiguration)
        _authStore = StateObject(wrappedValue: AuthStore())
        _webSocketService = StateObject(
            wrappedValue: WebSocketService(
                config: .init(serverURL: backendConfiguration.backendWebSocketURL)
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootContentView(hasCompletedOnboarding: $hasCompletedOnboarding)
                .environmentObject(backendConfiguration)
                .environmentObject(authStore)
                .environmentObject(webSocketService)
                .task {
                    webSocketService.updateServerURL(backendConfiguration.backendWebSocketURL)
                    await authStore.restoreSession(using: backendConfiguration)
                }
        }
    }
}

private struct RootContentView: View {
    @Binding var hasCompletedOnboarding: Bool

    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        if !hasCompletedOnboarding {
            OnboardingView()
        } else if case .restoring = authStore.status {
            LaunchLoadingView()
        } else if authStore.isAuthenticated {
            CameraSessionView()
        } else {
            SettingsView(allowsDismissal: false)
        }
    }
}

private struct LaunchLoadingView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .tint(.orange)
                    .scaleEffect(1.2)

                Text("Restoring your FixWise session...")
                    .font(.headline)
                    .foregroundColor(.white)
            }
        }
    }
}
