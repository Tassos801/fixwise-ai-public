import ARKit
import AVFoundation
import SwiftUI

enum GuidanceInputReadiness: Equatable {
    case sessionUnavailable
    case waitingForConnection
    case waitingForSceneFrame
    case ready

    static func resolve(
        hasStartedSession: Bool,
        canSendInteractiveMessages: Bool,
        hasSessionId: Bool,
        hasVisualContext: Bool,
        isTerminal: Bool
    ) -> GuidanceInputReadiness {
        guard hasStartedSession, hasSessionId, !isTerminal else {
            return .sessionUnavailable
        }
        guard canSendInteractiveMessages else {
            return .waitingForConnection
        }
        guard hasVisualContext else {
            return .waitingForSceneFrame
        }
        return .ready
    }

    var canInteract: Bool {
        self == .ready
    }

    var bannerText: String {
        switch self {
        case .sessionUnavailable:
            return "Start a live session to ask a question."
        case .waitingForConnection:
            return "Connecting to FixWise before prompt controls are enabled."
        case .waitingForSceneFrame:
            return "Hold the phone on the task for a moment so FixWise can see it before you ask."
        case .ready:
            return "Ask naturally about what you see, what to do next, or what looks unsafe."
        }
    }

    func blockedMessage(for inputMethod: String) -> String {
        switch self {
        case .sessionUnavailable:
            return "Start a live session before \(inputMethod)."
        case .waitingForConnection:
            return "FixWise is still connecting. Give it a moment before \(inputMethod)."
        case .waitingForSceneFrame:
            return "Hold the phone on the task for a moment so FixWise can see it before \(inputMethod)."
        case .ready:
            return ""
        }
    }
}

enum GuidanceTextSanitizer {
    static func userFacing(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let lower = trimmed.lowercased()
        // Filter out internal frame-acknowledgement messages — not useful to the user
        if lower.contains("latest frame for session") || lower.contains("i have your latest frame") {
            return ""
        }

        return trimmed
    }
}

struct CameraSessionView: View {
    @StateObject private var cameraService = CameraService()
    @StateObject private var sessionState = SessionState()
    @StateObject private var speechCaptureService = SpeechCaptureService()

    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var backendConfiguration: BackendConfigurationStore
    @EnvironmentObject private var webSocketService: WebSocketService

    @StateObject private var speechPlaybackService = SpeechPlaybackService()

    @State private var hasStartedSession = false
    @State private var hasConnectedOnce = false
    @State private var hasSentSceneFrame = false
    @State private var isTypedPromptPresented = false
    @State private var isSettingsPresented = false
    @State private var typedPrompt = ""
    @AppStorage("conversationModeEnabled") private var conversationMode = true

    var body: some View {
        ZStack {
            ARViewContainer(session: cameraService.arSession, showPlanes: hasStartedSession)
                .ignoresSafeArea()

            // AR analysis effects
            ScanLineView(isActive: isAnalyzing)
            CornerBracketsView(isActive: hasStartedSession && hasSentSceneFrame)

            AnnotationOverlayView(annotations: sessionState.annotations)

            VStack(spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        sessionInfoBadge
                        if let deploymentBadgeText = backendConfiguration.deploymentBadgeText {
                            deploymentBadge(text: deploymentBadgeText)
                        }
                    }
                    Spacer()
                    settingsButton
                }

                if !statusBannerText.isEmpty {
                    statusBanner
                }

                if shouldShowStarterPrompts {
                    starterPromptsView
                }

                Spacer()

                controlBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)

            if let overlay = sessionState.overlay {
                overlayView(for: overlay)
            }
        }
        .sheet(isPresented: $isTypedPromptPresented) {
            TypedPromptSheet(promptText: $typedPrompt) { prompt in
                submitPrompt(prompt)
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
        .onAppear { startSessionIfNeeded() }
        .onDisappear { stopSession(markCompleted: false) }
        .onChange(of: backendConfiguration.backendWebSocketURLString) { _, _ in
            webSocketService.updateServerURL(backendConfiguration.backendWebSocketURL)
        }
        .onReceive(cameraService.framePublisher) { encodedFrame in
            guard webSocketService.connectionState.isConnected,
                  let sessionId = sessionState.sessionId else { return }
            if webSocketService.sendFrame(encodedFrame, sessionId: sessionId) {
                hasSentSceneFrame = true
            }
        }
        .onReceive(webSocketService.responsePublisher) { response in
            handleResponse(response)
        }
        .onChange(of: webSocketService.connectionState) { _, newState in
            handleConnectionState(newState)
        }
        .onChange(of: hasSentSceneFrame) { _, isReady in
            guard isReady else { return }
            maybeStartHandsFreeListening()
        }
    }

    private var sessionInfoBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
            Text(formattedTime)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

private func deploymentBadge(text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.75), in: Capsule())
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.headline)
                .foregroundColor(.white)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusTitle)
                .font(.caption.bold())
                .foregroundColor(.white.opacity(0.75))
            Text(statusBannerText)
                .font(.subheadline)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var controlBar: some View {
        VStack(spacing: 12) {
            if hasStartedSession {
                conversationModeToggle

                HStack(spacing: 12) {
                    talkButton
                    typeButton
                    Spacer()
                    endSessionButton
                }
            } else {
                HStack {
                    restartSessionButton
                    Spacer()
                }
            }
        }
    }

    private var shouldShowStarterPrompts: Bool {
        canInteractWithGuidance
            && !speechCaptureService.isRecording
            && sessionState.currentStep == 0
            && sessionState.lastGuidanceText.isEmpty
    }

    private var starterPromptsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(starterPrompts, id: \.self) { prompt in
                    Button(prompt) {
                        submitPrompt(prompt)
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.45), in: Capsule())
                }
            }
        }
    }

    private var conversationModeToggle: some View {
        Toggle(
            isOn: Binding(
                get: { conversationMode },
                set: updateConversationMode
            )
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hands-Free Conversation")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text(
                    conversationMode
                    ? "FixWise will answer and then listen again automatically."
                    : "FixWise will wait until you tap Talk or Type."
                )
                .font(.caption)
                .foregroundColor(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(.green)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var talkButton: some View {
        Button(action: toggleTapToTalk) {
            Label(
                speechCaptureService.isRecording ? "Stop" : "Talk",
                systemImage: speechCaptureService.isRecording ? "stop.circle.fill" : "mic.circle.fill"
            )
            .font(.headline)
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                speechCaptureService.isRecording ? Color.orange.opacity(0.95) : Color.blue.opacity(0.9),
                in: Capsule()
            )
        }
        .disabled(!speechCaptureService.isRecording && !guidanceReadiness.canInteract)
        .opacity((speechCaptureService.isRecording || guidanceReadiness.canInteract) ? 1 : 0.55)
    }

    private var typeButton: some View {
        Button(action: presentTypedPrompt) {
            Label("Type", systemImage: "keyboard")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.45), in: Capsule())
        }
        .disabled(!guidanceReadiness.canInteract)
        .opacity(guidanceReadiness.canInteract ? 1 : 0.55)
    }

    private var endSessionButton: some View {
        Button(action: { stopSession(markCompleted: true) }) {
            Label("End", systemImage: "xmark.circle.fill")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.red.opacity(0.85), in: Capsule())
        }
    }

    private var restartSessionButton: some View {
        Button(action: restartSession) {
            Label(sessionState.isTerminal ? "New Session" : "Retry", systemImage: "arrow.clockwise.circle.fill")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.green.opacity(0.9), in: Capsule())
        }
    }

    @ViewBuilder
    private func overlayView(for overlay: SessionOverlay) -> some View {
        switch overlay {
        case .safety(let message):
            safetyBlockOverlay(message: message)
        case .error(let message):
            errorOverlay(message: message)
        }
    }

    private func safetyBlockOverlay(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 46))
                .foregroundColor(.yellow)

            Text("Safety Notice")
                .font(.title3.bold())
                .foregroundColor(.white)

            Text(message)
                .font(.body)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)

            Button("Continue") {
                sessionState.resumeListening()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(24)
    }

    private func errorOverlay(message: String) -> some View {
        let isBusy = message.localizedCaseInsensitiveContains("busy") || message.localizedCaseInsensitiveContains("wait")
        return VStack(spacing: 16) {
            Image(systemName: isBusy ? "hourglass.circle.fill" : "wifi.exclamationmark")
                .font(.system(size: 46))
                .foregroundColor(isBusy ? .yellow : .red)

            Text(isBusy ? "One Moment" : "Connection Problem")
                .font(.title3.bold())
                .foregroundColor(.white)

            Text(message)
                .font(.body)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)

            Button(isBusy ? "Try Again" : errorOverlayButtonTitle) {
                handleErrorOverlayAction()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(24)
    }

    private var connectionColor: Color {
        switch webSocketService.connectionState {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .yellow
        case .disconnected:
            return .red
        }
    }

    private var statusTitle: String {
        if speechCaptureService.isRecording {
            return "Listening"
        }

        switch sessionState.phase {
        case .connecting:
            return "Connecting"
        case .active(.processing):
            return "Analyzing"
        case .active(.responding):
            return "Guidance"
        case .ending:
            return "Ending"
        case .completed:
            return "Completed"
        case .error:
            return "Attention"
        default:
            return "Ready"
        }
    }

    private var statusBannerText: String {
        if speechCaptureService.isRecording {
            let transcript = speechCaptureService.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return transcript.isEmpty ? "Listening..." : transcript
        }

        if let runtimeIssue = cameraService.runtimeIssue {
            return runtimeIssue
        }

        if let error = speechCaptureService.lastErrorMessage {
            return error
        }

        if let warning = backendConfiguration.deviceTestingWarning,
           !webSocketService.connectionState.isConnected {
            return warning
        }

        if !sessionState.lastGuidanceText.isEmpty {
            return sessionState.lastGuidanceText
        }

        switch sessionState.phase {
        case .connecting:
            return "Connecting to the backend and starting the live camera session."
        case .active(.processing):
            return "FixWise is analyzing your latest frame."
        case .ending:
            return "Wrapping up this session."
        case .completed:
            return "Session complete."
        default:
            switch webSocketService.connectionState {
            case .reconnecting(let attempt):
                return "Backend connection lost. Reconnecting now (attempt \(attempt))."
            default:
                if guidanceReadiness == .ready && conversationMode {
                    return "Ask naturally. FixWise will keep listening after each answer."
                }
                return guidanceReadiness.bannerText
            }
        }
    }

    private var formattedTime: String {
        let minutes = Int(sessionState.elapsedTime) / 60
        let seconds = Int(sessionState.elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func startSessionIfNeeded() {
        guard !hasStartedSession else { return }
        hasStartedSession = true
        hasConnectedOnce = false
        hasSentSceneFrame = false

        _ = sessionState.startSession()

        // Only start AR if camera permission is granted
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .authorized {
            cameraService.startSession()
        }

        webSocketService.updateServerURL(backendConfiguration.backendWebSocketURL)
        webSocketService.connect(authToken: authStore.sessionToken)
    }

    private func stopSession(markCompleted: Bool) {
        guard hasStartedSession else { return }
        hasStartedSession = false
        hasSentSceneFrame = false

        speechCaptureService.cancelRecording()
        speechPlaybackService.stop()
        cameraService.stopSession()

        if let sessionId = sessionState.sessionId {
            _ = webSocketService.sendEndSession(sessionId: sessionId)
        }
        webSocketService.disconnect()

        if markCompleted {
            sessionState.endSession()
        } else {
            sessionState.reset()
        }
    }

    private func restartSession() {
        if let sessionId = sessionState.sessionId {
            _ = webSocketService.sendEndSession(sessionId: sessionId)
        }
        speechCaptureService.cancelRecording()
        speechPlaybackService.stop()
        cameraService.stopSession()
        webSocketService.disconnect()
        typedPrompt = ""
        isTypedPromptPresented = false
        hasSentSceneFrame = false
        sessionState.reset()
        hasStartedSession = false
        startSessionIfNeeded()
    }

    private func toggleTapToTalk() {
        if !speechCaptureService.isRecording && !guidanceReadiness.canInteract {
            presentOperationalError(guidanceReadiness.blockedMessage(for: "asking a question"))
            return
        }

        speechCaptureService.toggleRecording(
            onTranscriptReady: { prompt in
                submitPrompt(prompt)
            },
            onFallbackRequested: {
                isTypedPromptPresented = true
            }
        )
    }

    private func presentTypedPrompt() {
        guard guidanceReadiness.canInteract else {
            presentOperationalError(guidanceReadiness.blockedMessage(for: "sending a typed question"))
            return
        }
        isTypedPromptPresented = true
    }

    private func submitPrompt(_ prompt: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty,
              let sessionId = sessionState.sessionId else { return }

        guard guidanceReadiness.canInteract else {
            presentOperationalError(guidanceReadiness.blockedMessage(for: "sending that question"))
            return
        }

        guard !sessionState.isTerminal else { return }

        typedPrompt = ""
        if webSocketService.sendPrompt(trimmedPrompt, sessionId: sessionId) {
            sessionState.didStartProcessing()
        } else {
            presentOperationalError("Your prompt could not be sent. Please retry the session.")
        }
    }

    private func handleConnectionState(_ state: WebSocketService.ConnectionState) {
        switch state {
        case .connected:
            hasConnectedOnce = true
            sessionState.didConnect()
        case .connecting, .reconnecting:
            hasSentSceneFrame = false
            if !sessionState.isTerminal {
                sessionState.phase = .connecting
            }
        case .disconnected where hasStartedSession && hasConnectedOnce:
            hasSentSceneFrame = false
        case .disconnected:
            hasSentSceneFrame = false
            break
        }
    }

    private func handleResponse(_ response: WebSocketService.IncomingResponse) {
        switch response.type {
        case "safety_block":
            let reason = response.reason ?? "This task cannot be guided for safety reasons."
            let recommendation = response.recommendation?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String
            if let recommendation, !recommendation.isEmpty {
                message = "\(reason) \(recommendation)"
            } else {
                message = reason
            }
            sessionState.handleSafetyNotice(message)
        case "error":
            let rawError = GuidanceTextSanitizer.userFacing(
                response.message ?? "The backend could not process that request."
            )
            // Duration warnings aren't fatal — just speak them
            if rawError.contains("Warning:") && rawError.contains("seconds remaining") {
                speechPlaybackService.speak(rawError)
                return
            }
            if rawError.localizedCaseInsensitiveContains("frame must be sent") {
                hasSentSceneFrame = false
                sessionState.handleError(
                    "Hold the phone on the task for a moment so FixWise can see it, then ask again.",
                    shouldStopTimer: false
                )
                return
            }
            sessionState.handleError(rawError, shouldStopTimer: false)
        default:
            let annotations = response.annotations?.map { Annotation(from: $0) } ?? []
            let text = GuidanceTextSanitizer.userFacing(response.text ?? "")
            // Skip empty/internal messages — nothing to show or speak
            guard !text.isEmpty else { return }
            sessionState.didReceiveResponse(
                newAnnotations: annotations,
                text: text
            )
            speechPlaybackService.speak(text) {
                maybeStartHandsFreeListening()
            }
        }
    }

    private func autoListen() {
        guard canAutomaticallyListen else { return }
        speechCaptureService.startListening(
            onTranscriptReady: { prompt in
                submitPrompt(prompt)
            },
            onFallbackRequested: {
                // Silence — stay in conversation mode, don't pop keyboard
            }
        )
    }

    private func updateConversationMode(_ isEnabled: Bool) {
        conversationMode = isEnabled
        if isEnabled {
            maybeStartHandsFreeListening()
        }
    }

    private func maybeStartHandsFreeListening() {
        guard conversationMode else { return }
        autoListen()
    }

    private var canAutomaticallyListen: Bool {
        guard guidanceReadiness.canInteract,
              !speechCaptureService.isRecording,
              !speechPlaybackService.isSpeaking,
              sessionState.overlay == nil else {
            return false
        }

        if case .active(.processing) = sessionState.phase {
            return false
        }

        return true
    }

    private var isAnalyzing: Bool {
        if case .active(.processing) = sessionState.phase { return true }
        return false
    }

    private var guidanceReadiness: GuidanceInputReadiness {
        GuidanceInputReadiness.resolve(
            hasStartedSession: hasStartedSession,
            canSendInteractiveMessages: webSocketService.canSendInteractiveMessages,
            hasSessionId: sessionState.sessionId != nil,
            hasVisualContext: hasSentSceneFrame,
            isTerminal: sessionState.isTerminal
        )
    }

    private var canInteractWithGuidance: Bool {
        guidanceReadiness.canInteract
    }

    private var errorOverlayButtonTitle: String {
        if canInteractWithGuidance {
            return "Continue"
        }
        return hasStartedSession ? "Reconnect" : "Start New Session"
    }

    private func handleErrorOverlayAction() {
        if canInteractWithGuidance {
            sessionState.resumeListening()
        } else {
            restartSession()
        }
    }

    private func presentOperationalError(_ message: String) {
        sessionState.handleError(message, shouldStopTimer: false)
    }

    private var starterPrompts: [String] {
        [
            "What am I looking at?",
            "What should I do next?",
            "Is anything here unsafe?",
        ]
    }
}

// ARViewContainer, AnnotationOverlayView, ScanLineView, CornerBracketsView
// and Color(hex:) are defined in AROverlayViews.swift
