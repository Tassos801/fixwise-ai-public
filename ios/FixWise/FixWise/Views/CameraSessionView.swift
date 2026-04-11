import ARKit
import SwiftUI

struct CameraSessionView: View {
    @StateObject private var cameraService = CameraService()
    @StateObject private var sessionState = SessionState()
    @StateObject private var speechCaptureService = SpeechCaptureService()

    @EnvironmentObject private var authStore: AuthStore
    @EnvironmentObject private var backendConfiguration: BackendConfigurationStore
    @EnvironmentObject private var webSocketService: WebSocketService

    @State private var hasStartedSession = false
    @State private var hasConnectedOnce = false
    @State private var isTypedPromptPresented = false
    @State private var isSettingsPresented = false
    @State private var typedPrompt = ""

    private let speechPlaybackService = SpeechPlaybackService()

    var body: some View {
        ZStack {
            ARViewContainer(session: cameraService.arSession)
                .ignoresSafeArea()

            AnnotationOverlayView(annotations: sessionState.annotations)

            VStack(spacing: 16) {
                HStack(alignment: .top) {
                    sessionInfoBadge
                    Spacer()
                    settingsButton
                    stepCounter
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
            webSocketService.sendFrame(encodedFrame, sessionId: sessionId)
        }
        .onReceive(webSocketService.responsePublisher) { response in
            handleResponse(response)
        }
        .onChange(of: webSocketService.connectionState) { _, newState in
            handleConnectionState(newState)
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

    private var stepCounter: some View {
        Text("Step \(sessionState.currentStep)")
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
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
        HStack(spacing: 12) {
            if hasStartedSession {
                talkButton
                typeButton
                Spacer()
                endSessionButton
            } else {
                restartSessionButton
                Spacer()
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
        .disabled(!speechCaptureService.isRecording && !canInteractWithGuidance)
        .opacity((speechCaptureService.isRecording || canInteractWithGuidance) ? 1 : 0.55)
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
        .disabled(!canInteractWithGuidance)
        .opacity(canInteractWithGuidance ? 1 : 0.55)
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
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 46))
                .foregroundColor(.red)

            Text("Connection Problem")
                .font(.title3.bold())
                .foregroundColor(.white)

            Text(message)
                .font(.body)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)

            Button(errorOverlayButtonTitle) {
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
            return transcript.isEmpty ? "Speak your question, then tap Stop to submit it." : transcript
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
            case .connecting:
                return "Connecting to FixWise before prompt controls are enabled."
            default:
                return "Point the camera at the task area, then tap Talk or Type to ask for guidance."
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

        _ = sessionState.startSession()
        cameraService.startSession()
        webSocketService.updateServerURL(backendConfiguration.backendWebSocketURL)
        webSocketService.connect(authToken: authStore.sessionToken)
    }

    private func stopSession(markCompleted: Bool) {
        guard hasStartedSession else { return }
        hasStartedSession = false

        speechCaptureService.cancelRecording()
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
        cameraService.stopSession()
        webSocketService.disconnect()
        typedPrompt = ""
        isTypedPromptPresented = false
        sessionState.reset()
        hasStartedSession = false
        startSessionIfNeeded()
    }

    private func toggleTapToTalk() {
        if !speechCaptureService.isRecording && !canInteractWithGuidance {
            presentOperationalError("Wait for the backend connection before asking for guidance.")
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
        guard canInteractWithGuidance else {
            presentOperationalError("Wait for the backend connection before sending a typed question.")
            return
        }
        isTypedPromptPresented = true
    }

    private func submitPrompt(_ prompt: String) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty,
              let sessionId = sessionState.sessionId else { return }

        guard webSocketService.canSendInteractiveMessages else {
            presentOperationalError("FixWise is still connecting. Try again in a moment.")
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
            if !sessionState.isTerminal {
                sessionState.phase = .connecting
            }
        case .disconnected where hasStartedSession && hasConnectedOnce:
            sessionState.handleError("The backend connection was lost. Start a new session to reconnect.")
        case .disconnected:
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
            sessionState.handleError(
                response.message ?? "The backend could not process that request.",
                shouldStopTimer: false
            )
        default:
            let annotations = response.annotations?.map { Annotation(from: $0) } ?? []
            let text = response.text ?? "Guidance received."
            sessionState.didReceiveResponse(
                step: response.stepNumber ?? (sessionState.currentStep + 1),
                newAnnotations: annotations,
                text: text
            )
            speechPlaybackService.speak(text)
        }
    }

    private var canInteractWithGuidance: Bool {
        hasStartedSession
            && webSocketService.canSendInteractiveMessages
            && sessionState.sessionId != nil
            && !sessionState.isTerminal
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
            "Show me the next safe step.",
            "What tools do I need?",
        ]
    }
}

struct ARViewContainer: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct AnnotationOverlayView: View {
    let annotations: [Annotation]

    var body: some View {
        GeometryReader { geometry in
            ForEach(annotations) { annotation in
                annotationView(for: annotation, in: geometry.size)
            }
        }
    }

    @ViewBuilder
    private func annotationView(for annotation: Annotation, in size: CGSize) -> some View {
        switch annotation.type {
        case .circle:
            if let x = annotation.x, let y = annotation.y {
                let radius = CGFloat(annotation.radius ?? 0.05) * min(size.width, size.height)
                Circle()
                    .stroke(Color(hex: annotation.color) ?? .orange, lineWidth: 3)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height)
                    .overlay {
                        annotationLabel(annotation.label)
                            .position(
                                x: CGFloat(x) * size.width,
                                y: CGFloat(y) * size.height - radius - 16
                            )
                    }
            }

        case .label:
            if let x = annotation.x, let y = annotation.y {
                annotationLabel(annotation.label)
                    .background(
                        (Color(hex: annotation.color) ?? .orange).opacity(0.9),
                        in: Capsule()
                    )
                    .position(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height)
            }

        case .arrow:
            if let from = annotation.from, let to = annotation.to {
                let color = Color(hex: annotation.color) ?? .green
                let fromPoint = CGPoint(x: CGFloat(from.x) * size.width, y: CGFloat(from.y) * size.height)
                let toPoint = CGPoint(x: CGFloat(to.x) * size.width, y: CGFloat(to.y) * size.height)

                Path { path in
                    path.move(to: fromPoint)
                    path.addLine(to: toPoint)

                    let angle = atan2(toPoint.y - fromPoint.y, toPoint.x - fromPoint.x)
                    let arrowLength: CGFloat = 14
                    let arrowAngle: CGFloat = .pi / 7

                    let leftPoint = CGPoint(
                        x: toPoint.x - arrowLength * cos(angle - arrowAngle),
                        y: toPoint.y - arrowLength * sin(angle - arrowAngle)
                    )
                    let rightPoint = CGPoint(
                        x: toPoint.x - arrowLength * cos(angle + arrowAngle),
                        y: toPoint.y - arrowLength * sin(angle + arrowAngle)
                    )

                    path.move(to: toPoint)
                    path.addLine(to: leftPoint)
                    path.move(to: toPoint)
                    path.addLine(to: rightPoint)
                }
                .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

                annotationLabel(annotation.label)
                    .background(color.opacity(0.9), in: Capsule())
                    .position(
                        x: (fromPoint.x + toPoint.x) / 2,
                        y: (fromPoint.y + toPoint.y) / 2 - 18
                    )
            }

        case .boundingBox:
            if let from = annotation.from, let to = annotation.to {
                let color = Color(hex: annotation.color) ?? .yellow
                let rect = CGRect(
                    x: min(CGFloat(from.x), CGFloat(to.x)) * size.width,
                    y: min(CGFloat(from.y), CGFloat(to.y)) * size.height,
                    width: abs(CGFloat(to.x - from.x)) * size.width,
                    height: abs(CGFloat(to.y - from.y)) * size.height
                )

                Rectangle()
                    .stroke(color, lineWidth: 3)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .overlay {
                        annotationLabel(annotation.label)
                            .background(color.opacity(0.9), in: Capsule())
                            .position(x: rect.midX, y: rect.minY - 16)
                    }
            }
        }
    }

    private func annotationLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.72), in: Capsule())
    }
}

extension Color {
    init?(hex: String) {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        sanitized = sanitized.replacingOccurrences(of: "#", with: "")

        guard sanitized.count == 6,
              let rgb = UInt64(sanitized, radix: 16) else {
            return nil
        }

        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
