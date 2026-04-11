import AVFoundation
import Speech
import SwiftUI

struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var disclaimerAccepted = false
    @State private var cameraStatus: PermissionStatus = .notDetermined
    @State private var microphoneStatus: PermissionStatus = .notDetermined
    @State private var speechStatus: PermissionStatus = .notDetermined

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 32) {
                    Spacer().frame(height: 24)

                    // MARK: - Logo & Tagline

                    VStack(spacing: 12) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 56))
                            .foregroundColor(.orange)

                        Text("FixWise AI")
                            .font(.system(size: 34, weight: .bold, design: .default))
                            .foregroundColor(.white)

                        Text("Expert guidance, hands-free")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.bottom, 8)

                    // MARK: - Disclaimer

                    VStack(alignment: .leading, spacing: 16) {
                        Label("Important Disclaimer", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundColor(.orange)

                        Text("FixWise AI provides general guidance only. It is not a substitute for a licensed professional. You assume all responsibility for actions taken based on AI guidance.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)

                        Button(action: { disclaimerAccepted.toggle() }) {
                            HStack(spacing: 12) {
                                Image(systemName: disclaimerAccepted ? "checkmark.square.fill" : "square")
                                    .font(.title3)
                                    .foregroundColor(disclaimerAccepted ? .orange : .white.opacity(0.5))

                                Text("I understand and accept")
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(20)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))

                    // MARK: - Permissions

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Permissions")
                            .font(.headline)
                            .foregroundColor(.white)

                        permissionRow(
                            icon: "camera.fill",
                            title: "Camera",
                            subtitle: "Required for live video guidance",
                            status: cameraStatus,
                            action: requestCameraPermission
                        )

                        permissionRow(
                            icon: "mic.fill",
                            title: "Microphone",
                            subtitle: "For voice commands",
                            status: microphoneStatus,
                            action: requestMicrophonePermission
                        )

                        permissionRow(
                            icon: "waveform",
                            title: "Speech Recognition",
                            subtitle: "For spoken question transcription",
                            status: speechStatus,
                            action: requestSpeechPermission
                        )
                    }
                    .padding(20)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))

                    // MARK: - Get Started

                    Button(action: { hasCompletedOnboarding = true }) {
                        Text("Get Started")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                canProceed ? Color.orange : Color.orange.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                    }
                    .disabled(!canProceed)

                    if !canProceed {
                        Text(proceedHint)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                            .multilineTextAlignment(.center)
                    }

                    Text("After onboarding, open Settings to sign in and point FixWise at your backend before you start a live session.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.45))
                        .multilineTextAlignment(.center)

                    Spacer().frame(height: 24)
                }
                .padding(.horizontal, 24)
            }
        }
        .onAppear { refreshPermissionStatuses() }
    }

    // MARK: - Permission Row

    private func permissionRow(
        icon: String,
        title: String,
        subtitle: String,
        status: PermissionStatus,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()

            permissionBadge(for: status, requestAction: action)
        }
    }

    @ViewBuilder
    private func permissionBadge(for status: PermissionStatus, requestAction: @escaping () -> Void) -> some View {
        switch status {
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill")
                .font(.caption.bold())
                .foregroundColor(.green)

        case .denied:
            Button("Settings") { openAppSettings() }
                .font(.caption.bold())
                .foregroundColor(.orange)

        case .notDetermined:
            Button("Allow") { requestAction() }
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange, in: Capsule())
        }
    }

    // MARK: - State Helpers

    private var canProceed: Bool {
        disclaimerAccepted && cameraStatus == .granted
    }

    private var proceedHint: String {
        if !disclaimerAccepted && cameraStatus != .granted {
            return "Accept the disclaimer and grant camera access to continue."
        } else if !disclaimerAccepted {
            return "Accept the disclaimer to continue."
        } else {
            return "Camera permission is required to continue."
        }
    }

    // MARK: - Permission Requests

    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async { refreshPermissionStatuses() }
        }
    }

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { refreshPermissionStatuses() }
        }
    }

    private func requestSpeechPermission() {
        SFSpeechRecognizer.requestAuthorization { _ in
            DispatchQueue.main.async { refreshPermissionStatuses() }
        }
    }

    private func refreshPermissionStatuses() {
        // Camera
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraStatus = .granted
        case .denied, .restricted: cameraStatus = .denied
        default: cameraStatus = .notDetermined
        }

        // Microphone
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphoneStatus = .granted
        case .denied, .restricted: microphoneStatus = .denied
        default: microphoneStatus = .notDetermined
        }

        // Speech Recognition
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speechStatus = .granted
        case .denied, .restricted: speechStatus = .denied
        default: speechStatus = .notDetermined
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Permission Status

private enum PermissionStatus {
    case notDetermined
    case granted
    case denied
}
