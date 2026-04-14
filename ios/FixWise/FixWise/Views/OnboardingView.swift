import AVFoundation
import Speech
import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var cameraGranted = false
    @State private var didRequestPermissions = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 36) {
                Spacer()

                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 64))
                    .foregroundColor(.orange)

                Text("FixWise AI")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundColor(.white)

                Text("Point your camera at any task.\nAsk a question. Get guidance.")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)

                Spacer()

                if !didRequestPermissions {
                    Button(action: requestAllPermissions) {
                        Label("Allow Camera & Start", systemImage: "camera.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 14))
                    }
                } else if cameraGranted {
                    Button(action: { hasCompletedOnboarding = true }) {
                        Label("Get Started", systemImage: "arrow.right.circle.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 14))
                    }
                } else {
                    VStack(spacing: 12) {
                        Text("Camera access is required for FixWise to work.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center)

                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .font(.headline)
                        .foregroundColor(.orange)
                    }
                }

                Text("AI guidance only — not a substitute for a licensed professional.")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.35))
                    .multilineTextAlignment(.center)

                Spacer().frame(height: 16)
            }
            .padding(.horizontal, 32)
        }
        .onAppear { checkCamera() }
    }

    private func requestAllPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                cameraGranted = granted
                didRequestPermissions = true
                if granted {
                    // Auto-proceed after a brief moment
                    hasCompletedOnboarding = true
                }
            }
        }
        // Request mic and speech in parallel — non-blocking
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    private func checkCamera() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraGranted = status == .authorized
        didRequestPermissions = status != .notDetermined
        if cameraGranted {
            // Already granted from previous install — skip onboarding
            hasCompletedOnboarding = true
        }
    }
}
