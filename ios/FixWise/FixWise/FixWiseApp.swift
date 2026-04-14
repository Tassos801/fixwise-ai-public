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
            }
        }
    }
}

private struct RootContentView: View {
    @Binding var hasCompletedOnboarding: Bool

    var body: some View {
        if hasCompletedOnboarding {
            CameraSessionView()
        } else {
            OnboardingView()
        }
    }
}
