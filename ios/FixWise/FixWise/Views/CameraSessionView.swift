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
        if lower.contains("latest frame for session") || lower.contains("i have your latest frame") {
            return "I can see the area you mean. Hold the phone steady and I'll guide the next small step."
        }

        return trimmed
    }
}

// MARK: - Main Camera Session View

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
    @State private var isRecapPresented = false
    @State private var typedPrompt = ""
    @State private var recapReportURL: URL?
    @State private var suggestedGuidanceMode: GuidanceMode?
    @State private var dismissedSuggestedModes: Set<GuidanceMode> = []
    @AppStorage("conversationModeEnabled") private var conversationMode = true
    @AppStorage(GuidanceMode.storageKey) private var storedGuidanceModeRawValue = GuidanceMode.general.rawValue

    // MARK: - Liquid Glass UI State
    @State private var isStatusExpanded = false
    @State private var isModePickerVisible = false
    @State private var guidanceToastText: String = ""
    @State private var guidanceToastVisible = false
    @State private var guidanceToastWorkItem: DispatchWorkItem?
    /// Shows a "Waking backend…" hint when the WebSocket has been in a
    /// connecting state long enough that a Render free-tier cold start is
    /// the most likely cause.
    @State private var isBackendWarming = false
    @State private var warmingHintTask: Task<Void, Never>?

    // MARK: - Camera UI State (zoom / focus / flash)
    /// Zoom factor at the start of the current pinch gesture.
    @State private var pinchBaseZoom: CGFloat = 1.0
    /// Point in view-space where the focus reticle should render.
    @State private var focusReticlePoint: CGPoint?
    /// Monotonic token that changes on every tap — drives reticle re-animation.
    @State private var focusReticleToken: Int = 0
    /// Work item that clears the reticle after it fades.
    @State private var focusReticleClearItem: DispatchWorkItem?
    /// Momentary zoom-HUD visibility (shown while user is actively zooming).
    @State private var zoomHUDVisible = false
    @State private var zoomHUDWorkItem: DispatchWorkItem?
    /// Whether the torch level slider is revealed (long-press / tap on level chip).
    @State private var isTorchSliderVisible = false
    /// Whether AE/AF is currently locked (set by long-press).
    @State private var isExposureLocked = false

    var body: some View {
        ZStack {
            // Full-screen AR camera with gesture handlers
            ARViewContainer(
                session: cameraService.arSession,
                showPlanes: hasStartedSession,
                onPinchScale: handlePinchScale,
                onTapToFocus: handleTapToFocus,
                onDoubleTap: handleDoubleTapZoom,
                onLongPress: handleLongPressLock
            )
            .ignoresSafeArea()

            // AR effects — non-blocking
            ScanLineView(isActive: isAnalyzing)
            CornerBracketsView(isActive: hasStartedSession && hasSentSceneFrame)

            // Tap-to-focus reticle (and AE/AF lock indicator)
            FocusReticleView(
                position: focusReticlePoint,
                token: focusReticleToken,
                isLocked: isExposureLocked
            )

            // Annotations on top of camera
            AnnotationOverlayView(annotations: sessionState.annotations)

            // === UI Layer — edges only, center stays clear ===
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                // Expandable status card
                if isStatusExpanded {
                    expandedStatusCard
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                }

                // Mode picker — slides in/out
                if isModePickerVisible {
                    modePickerStrip
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        ))
                }

                Spacer()

                // Floating guidance toast — appears briefly mid-screen
                if guidanceToastVisible {
                    guidanceToast
                        .padding(.horizontal, 24)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity),
                            removal: .opacity
                        ))
                }

                Spacer()

                // Zoom HUD — momentary while zooming
                if zoomHUDVisible {
                    zoomHUDView
                        .padding(.bottom, 4)
                        .transition(.opacity)
                }

                // Zoom quick-switch strip (0.5x / 1x / 2x / 3x)
                if hasStartedSession && cameraService.zoomSwitchPoints.count > 1 {
                    zoomSwitchStrip
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }

                // Torch level slider (appears when user taps torch chip)
                if isTorchSliderVisible && cameraService.hasTorch {
                    torchLevelSlider
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Task copilot — structured setup progress for Machines & Tech
                if shouldShowTaskCopilot {
                    taskCopilotPanel
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Follow-up prompts — just above controls
                if shouldShowFollowUpPrompts {
                    followUpChipsView
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Bottom control bar
                bottomControlBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            // Full-screen overlays (safety/error)
            if let overlay = sessionState.overlay {
                overlayView(for: overlay)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: isStatusExpanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: isModePickerVisible)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: guidanceToastVisible)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: shouldShowFollowUpPrompts)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: shouldShowTaskCopilot)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isTorchSliderVisible)
        .animation(.easeInOut(duration: 0.18), value: zoomHUDVisible)
        .animation(.easeInOut(duration: 0.3), value: sessionState.overlay != nil)
        .sheet(isPresented: $isTypedPromptPresented) {
            TypedPromptSheet(promptText: $typedPrompt, mode: selectedGuidanceMode) { prompt in
                submitPrompt(prompt)
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $isRecapPresented, onDismiss: {
            recapReportURL = nil
        }) {
            SessionRecapView(
                isGuestSession: authStore.isGuestSession,
                summary: sessionState.recapSummaryText,
                nextAction: sessionState.recapNextActionText,
                reportURL: recapReportURL,
                guidanceConfidence: sessionState.guidanceConfidence,
                followUpPrompts: sessionState.visibleFollowUpPrompts,
                onOpenHistory: { isSettingsPresented = true },
                onStartAnotherSession: { restartSession() }
            )
        }
        .onAppear { startSessionIfNeeded() }
        .onDisappear { stopSession(markCompleted: false) }
        .onChange(of: backendConfiguration.backendWebSocketURLString) { _, _ in
            webSocketService.updateServerURL(backendConfiguration.backendWebSocketURL)
        }
        .onChange(of: backendConfiguration.backendHTTPURLString) { _, _ in
            Task { _ = await backendConfiguration.refreshHealth() }
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
            // Auto-collapse status once ready
            if guidanceReadiness == .ready {
                withAnimation { isStatusExpanded = false }
            }
        }
        .onChange(of: sessionState.phase) { _, newPhase in
            if case .completed(let reportURL) = newPhase {
                recapReportURL = reportURL
                isRecapPresented = true
            }
        }
        .onChange(of: guidanceReadiness) { _, newReadiness in
            if newReadiness == .ready && isStatusExpanded {
                // Auto-collapse 1.5s after becoming ready
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    if guidanceReadiness == .ready {
                        withAnimation { isStatusExpanded = false }
                    }
                }
            }
        }
        .onChange(of: sessionState.lastGuidanceText) { _, newText in
            if !newText.isEmpty {
                showGuidanceToast(newText)
            }
        }
    }

    // MARK: - Computed Properties

    private var selectedGuidanceMode: GuidanceMode {
        GuidanceMode.resolved(rawValue: storedGuidanceModeRawValue)
    }

    private var visibleSuggestedMode: GuidanceMode? {
        guard let suggestedGuidanceMode,
              suggestedGuidanceMode != selectedGuidanceMode,
              !dismissedSuggestedModes.contains(suggestedGuidanceMode) else {
            return nil
        }
        return suggestedGuidanceMode
    }

    // MARK: - Top Bar (Compact Pill)

    private var topBar: some View {
        HStack(spacing: 10) {
            // Tappable status pill
            Button {
                withAnimation { isStatusExpanded.toggle() }
                if isStatusExpanded { isModePickerVisible = false }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 8, height: 8)

                    Text(compactStatusText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(formattedTime)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Image(systemName: isStatusExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)

            Spacer()

            // Mode button
            Button {
                withAnimation { isModePickerVisible.toggle() }
                if isModePickerVisible { isStatusExpanded = false }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedGuidanceMode.systemImage)
                        .font(.caption.weight(.semibold))
                    if !isModePickerVisible {
                        Text(selectedGuidanceMode.title)
                            .font(.caption2.weight(.semibold))
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)

            // Flash / torch button (only when device has a torch)
            if hasStartedSession && cameraService.hasTorch {
                flashButton
            }

            // Settings button
            Button { isSettingsPresented = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .padding(10)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Flash / Torch Controls

    /// Long-press wins via the `highPriorityGesture`; a short tap falls through
    /// to the tap gesture. This avoids the Button + simultaneousGesture bug
    /// where both actions fired on a long press.
    private var flashButton: some View {
        Image(systemName: flashButtonSymbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(flashButtonTint)
            .frame(width: 36, height: 36)
            .glassEffect(.regular.interactive(), in: .circle)
            .contentShape(Circle())
            .highPriorityGesture(
                LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    guard cameraService.hasTorch else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation { isTorchSliderVisible.toggle() }
                }
            )
            .onTapGesture { cycleFlashMode() }
            .accessibilityLabel(flashAccessibilityLabel)
            .accessibilityHint("Double-tap to cycle flash mode. Long-press to adjust brightness.")
    }

    /// Cycle off → on → auto → off (or on → auto only in bright light).
    private func cycleFlashMode() {
        if cameraService.autoTorchEnabled {
            // auto → off
            cameraService.setAutoTorch(enabled: false)
            if cameraService.torchOn { cameraService.setTorch(on: false) }
            showGuidanceToast("Flash off")
        } else if cameraService.torchOn {
            // on → auto (surface what auto will do if ambient is already bright)
            cameraService.setTorch(on: false)
            cameraService.setAutoTorch(enabled: true)
            let ambient = cameraService.ambientLightIntensity
            if ambient > cameraService.config.autoTorchOffLumens {
                showGuidanceToast("Flash: auto (staying off — scene is already bright)")
            } else if ambient > 0 && ambient < cameraService.config.autoTorchOnLumens {
                showGuidanceToast("Flash: auto (will turn on in low light)")
            } else {
                showGuidanceToast("Flash: auto")
            }
        } else {
            // off → on
            cameraService.setTorch(on: true)
            showGuidanceToast("Flash on · \(Int(cameraService.torchLevel * 100))%")
        }
    }

    private var flashAccessibilityLabel: String {
        if cameraService.autoTorchEnabled { return "Flash auto" }
        if cameraService.torchOn { return "Flash on" }
        return "Flash off"
    }

    private var flashButtonSymbol: String {
        if cameraService.autoTorchEnabled { return "bolt.badge.a.fill" }
        if cameraService.torchOn { return "bolt.fill" }
        return "bolt.slash.fill"
    }

    private var flashButtonTint: Color {
        if cameraService.autoTorchEnabled { return .cyan }
        if cameraService.torchOn { return .yellow }
        return .primary
    }

    private var torchLevelSlider: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
            Slider(
                value: Binding(
                    get: { Double(cameraService.torchLevel) },
                    set: { cameraService.setTorchLevel(Float($0)) }
                ),
                in: 0.1...1.0
            )
            .tint(.yellow)
            Text("\(Int(cameraService.torchLevel * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 40, alignment: .trailing)
            Button {
                withAnimation { isTorchSliderVisible = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Zoom UI

    private var zoomSwitchStrip: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(cameraService.zoomSwitchPoints, id: \.self) { point in
                zoomSwitchPill(for: point)
            }
            Spacer(minLength: 0)
        }
    }

    private func zoomSwitchPill(for point: CGFloat) -> some View {
        let isActive = abs(cameraService.zoomFactor - point) < 0.05
        let label = formatZoomLabel(point, active: isActive)
        return Button {
            cameraService.setZoomFactor(point, ramp: true, rate: 8.0)
            showZoomHUD()
        } label: {
            Text(label)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(isActive ? Color.yellow : Color.white.opacity(0.9))
                .frame(minWidth: 36, minHeight: 36)
                .padding(.horizontal, 6)
                .background(
                    Circle()
                        .fill(Color.black.opacity(isActive ? 0.55 : 0.35))
                )
                .overlay(
                    Circle()
                        .stroke(isActive ? Color.yellow.opacity(0.7) : Color.white.opacity(0.18), lineWidth: 1)
                )
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
    }

    private func formatZoomLabel(_ value: CGFloat, active: Bool) -> String {
        if active {
            // Show the live zoom. If it rounds to an integer (e.g. 2.0), drop the decimal.
            let live = cameraService.zoomFactor
            if abs(live - live.rounded()) < 0.05 {
                return String(format: "%.0f×", live.rounded())
            }
            return String(format: "%.1f×", live)
        }
        // Inactive pill: compact labels — ".5" for sub-1×, "1" / "2" / "3" for whole.
        if value < 1 {
            return String(format: ".%d", Int((value * 10).rounded()))
        }
        if abs(value - value.rounded()) < 0.05 {
            return String(format: "%.0f", value.rounded())
        }
        return String(format: "%.1f", value)
    }

    private var zoomHUDView: some View {
        let z = cameraService.zoomFactor
        let label = abs(z - z.rounded()) < 0.05
            ? String(format: "%.0f×", z.rounded())
            : String(format: "%.1f×", z)
        return Text(label)
            .font(.title3.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.55), in: Capsule())
            .glassEffect(.regular, in: .capsule)
    }

    private var compactStatusText: String {
        if speechCaptureService.isRecording { return "Listening" }
        if speechPlaybackService.isSpeaking { return "Speaking" }
        switch sessionState.phase {
        case .connecting: return isBackendWarming ? "Waking backend…" : "Connecting"
        case .active(.processing): return "Thinking"
        case .active(.responding): return "Guiding"
        case .ending: return "Ending"
        case .completed: return "Done"
        case .error: return "Error"
        default: return guidanceReadiness == .ready ? "Ready" : "Setting up"
        }
    }

    // MARK: - Expanded Status Card

    private var expandedStatusCard: some View {
        let providerState = backendConfiguration.backendHealth?.displayProviderName ?? backendConfiguration.deploymentBadgeText ?? "Hosted Beta"
        let providerSubtitle = backendConfiguration.backendHealth?.guidanceHint(hasSavedAPIKey: authStore.user?.hasApiKey ?? false)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(readinessTitle(for: guidanceReadiness))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(stateSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                statusBadge(text: providerState, color: providerColor)
            }

            readinessLine(icon: "antenna.radiowaves.left.and.right", title: "Provider", value: providerLineText(providerState: providerState, hint: providerSubtitle))
            readinessLine(icon: "camera.viewfinder", title: "Frame", value: frameLineText())
            readinessLine(icon: speechCaptureService.isRecording ? "mic.circle.fill" : "mic.circle", title: "Voice", value: voiceLineText())
            readinessLine(icon: selectedGuidanceMode.systemImage, title: "Mode", value: selectedGuidanceMode.readinessHint)
            readinessLine(icon: "camera.metering.center.weighted", title: "Optics", value: opticsLineText())

            if let deploymentBadgeText = backendConfiguration.deploymentBadgeText {
                HStack {
                    Spacer()
                    Text(deploymentBadgeText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private var stateSubtitle: String {
        if speechCaptureService.isRecording { return "Listening to your question." }
        if speechPlaybackService.isSpeaking { return "Speaking the last answer." }
        switch sessionState.phase {
        case .connecting: return "Connecting the live session."
        case .active(.processing): return "Thinking with the latest frame."
        case .active(.responding): return "Showing guidance and follow-up prompts."
        case .ending: return "Wrapping up the session."
        case .completed: return "Session complete."
        case .error(let message): return message
        default:
            return guidanceReadiness == .ready ? selectedGuidanceMode.readinessHint : guidanceReadiness.bannerText
        }
    }

    // MARK: - Mode Picker Strip

    private var modePickerStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(GuidanceMode.allCases) { mode in
                        Button {
                            setSelectedGuidanceMode(mode)
                            // Auto-dismiss after selection
                            Task {
                                try? await Task.sleep(for: .seconds(0.5))
                                withAnimation { isModePickerVisible = false }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: mode.systemImage)
                                    .font(.caption2.weight(.semibold))
                                Text(mode.title)
                                    .font(.caption2.weight(.semibold))
                            }
                            .foregroundStyle(mode == selectedGuidanceMode ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                mode == selectedGuidanceMode
                                    ? AnyShapeStyle(Color.blue.opacity(0.85))
                                    : AnyShapeStyle(.clear),
                                in: Capsule()
                            )
                            .glassEffect(
                                mode == selectedGuidanceMode ? .regular : .regular.interactive(),
                                in: .capsule
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }

            // Suggested mode banner
            if let suggestedMode = visibleSuggestedMode {
                HStack(spacing: 10) {
                    Image(systemName: suggestedMode.systemImage)
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(suggestedMode.suggestionTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Button("Use") {
                        setSelectedGuidanceMode(suggestedMode)
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular.interactive(), in: .capsule)

                    Button {
                        dismissSuggestedMode(suggestedMode)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    // MARK: - Guidance Toast (Auto-Dismissing)

    private var guidanceToast: some View {
        Text(guidanceToastText)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: 340)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func showGuidanceToast(_ text: String) {
        guidanceToastWorkItem?.cancel()
        guidanceToastText = text
        withAnimation { guidanceToastVisible = true }
        let work = DispatchWorkItem { [self] in
            withAnimation { self.guidanceToastVisible = false }
        }
        guidanceToastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    // MARK: - Task Copilot

    private var shouldShowTaskCopilot: Bool {
        hasStartedSession && selectedGuidanceMode == .machines && sessionState.taskState != nil
    }

    @ViewBuilder
    private var taskCopilotPanel: some View {
        if let taskState = sessionState.taskState {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selectedGuidanceMode.systemImage)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.cyan)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(taskState.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text("\(taskState.setupTypeTitle) · \(taskState.phaseTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }

                    Spacer(minLength: 8)

                    if taskState.totalChecklistCount > 0 {
                        Text("\(taskState.completedChecklistCount)/\(taskState.totalChecklistCount)")
                            .font(.caption.monospacedDigit().weight(.bold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.18), in: Capsule())
                    }
                }

                if let activeItem = taskState.activeChecklistItem {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: checklistIcon(for: activeItem))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(checklistColor(for: activeItem))
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(activeItem.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)

                            if let detail = activeItem.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                if !taskState.checklist.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(taskState.checklist.prefix(4)) { item in
                            Capsule()
                                .fill(checklistColor(for: item).opacity(item.isActive ? 0.9 : 0.45))
                                .frame(height: 4)
                        }
                    }
                    .frame(height: 4)
                }

                if !taskState.visibleComponents.isEmpty || taskState.troubleshootingTitle != nil {
                    HStack(spacing: 6) {
                        ForEach(taskState.visibleComponents.prefix(3)) { component in
                            HStack(spacing: 5) {
                                Image(systemName: componentIcon(for: component.kind))
                                    .font(.caption2.weight(.bold))
                                Text(component.label)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.16), in: Capsule())
                        }

                        if let troubleshootingTitle = taskState.troubleshootingTitle {
                            HStack(spacing: 5) {
                                Image(systemName: "stethoscope")
                                    .font(.caption2.weight(.bold))
                                Text(troubleshootingTitle)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.orange.opacity(0.16), in: Capsule())
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 430)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    private func checklistIcon(for item: GuidanceChecklistItem) -> String {
        switch item.status.normalizedTaskStatus {
        case "done", "complete", "completed":
            return "checkmark.circle.fill"
        case "active":
            return "arrow.right.circle.fill"
        case "blocked":
            return "exclamationmark.triangle.fill"
        default:
            return "circle"
        }
    }

    private func checklistColor(for item: GuidanceChecklistItem) -> Color {
        switch item.status.normalizedTaskStatus {
        case "done", "complete", "completed":
            return .green
        case "active":
            return .cyan
        case "blocked":
            return .orange
        default:
            return .secondary
        }
    }

    private func componentIcon(for kind: String) -> String {
        switch kind {
        case "port":
            return "arrow.left.arrow.right"
        case "cable":
            return "cable.connector"
        case "component":
            return "cpu"
        case "slot":
            return "rectangle.connected.to.line.below"
        case "header":
            return "switch.2"
        case "device":
            return "externaldrive"
        default:
            return "questionmark.circle"
        }
    }

    // MARK: - Follow-Up Chips

    private var shouldShowFollowUpPrompts: Bool {
        !sessionState.visibleFollowUpPrompts.isEmpty && canInteractWithGuidance
    }

    private var followUpChipsView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(sessionState.visibleFollowUpPrompts, id: \.self) { prompt in
                    Button(prompt) { submitPrompt(prompt) }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Bottom Control Bar

    private var bottomControlBar: some View {
        VStack(spacing: 10) {
            if hasStartedSession {
                // Conversation mode toggle — compact
                if guidanceReadiness == .ready {
                    conversationModeToggle
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack(spacing: 10) {
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
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: hasStartedSession)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: guidanceReadiness == .ready)
    }

    private var conversationModeToggle: some View {
        HStack(spacing: 10) {
            Image(systemName: conversationMode ? "waveform.circle.fill" : "waveform.circle")
                .font(.subheadline)
                .foregroundStyle(conversationMode ? .green : .secondary)

            Text("Hands-Free")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            Spacer()

            Toggle("", isOn: Binding(
                get: { conversationMode },
                set: updateConversationMode
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.green)
            .scaleEffect(0.8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private var talkButton: some View {
        Button(action: toggleTapToTalk) {
            HStack(spacing: 6) {
                Image(systemName: speechCaptureService.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.headline)
                    .symbolEffect(.pulse, isActive: speechCaptureService.isRecording)
                Text(speechCaptureService.isRecording ? "Stop" : "Talk")
                    .font(.subheadline.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                speechCaptureService.isRecording ? Color.orange.opacity(0.9) : Color.blue.opacity(0.85),
                in: Capsule()
            )
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!speechCaptureService.isRecording && !guidanceReadiness.canInteract)
        .opacity((speechCaptureService.isRecording || guidanceReadiness.canInteract) ? 1 : 0.45)
    }

    private var typeButton: some View {
        Button(action: presentTypedPrompt) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.subheadline)
                Text("Type")
                    .font(.subheadline.weight(.bold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!guidanceReadiness.canInteract)
        .opacity(guidanceReadiness.canInteract ? 1 : 0.45)
    }

    private var endSessionButton: some View {
        Button(action: { stopSession(markCompleted: true) }) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .font(.subheadline)
                Text("End")
                    .font(.subheadline.weight(.bold))
            }
            .foregroundStyle(.red)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private var restartSessionButton: some View {
        Button(action: restartSession) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.headline)
                Text(sessionState.isTerminal ? "New Session" : "Retry")
                    .font(.subheadline.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .background(Color.green.opacity(0.85), in: Capsule())
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Overlays (Safety / Error)

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
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.yellow)

                Text("Safety Notice")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Continue") {
                    sessionState.resumeListening()
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(Color.blue, in: Capsule())
            }
            .padding(28)
            .frame(maxWidth: 340)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }

    private func errorOverlay(message: String) -> some View {
        let isBusy = message.localizedCaseInsensitiveContains("busy") || message.localizedCaseInsensitiveContains("wait")
        return ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: isBusy ? "hourglass.circle.fill" : "wifi.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(isBusy ? .yellow : .red)

                Text(isBusy ? "One Moment" : "Connection Problem")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(isBusy ? "Try Again" : errorOverlayButtonTitle) {
                    handleErrorOverlayAction()
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(Color.blue, in: Capsule())
            }
            .padding(28)
            .frame(maxWidth: 340)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
    }

    // MARK: - Helper Views

    private var connectionColor: Color {
        switch webSocketService.connectionState {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .disconnected: return .red
        }
    }

    private var formattedTime: String {
        let minutes = Int(sessionState.elapsedTime) / 60
        let seconds = Int(sessionState.elapsedTime) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
    }

    private func readinessLine(icon: String, title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Session Logic

    private func startSessionIfNeeded() {
        guard !hasStartedSession else { return }
        hasStartedSession = true
        hasConnectedOnce = false
        hasSentSceneFrame = false
        isRecapPresented = false
        recapReportURL = nil
        suggestedGuidanceMode = nil
        dismissedSuggestedModes = []
        isStatusExpanded = true  // Show expanded on start

        _ = sessionState.startSession()

        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .authorized {
            cameraService.startSession()
        }

        webSocketService.updateServerURL(backendConfiguration.backendWebSocketURL)
        webSocketService.connect(authToken: authStore.tokenForOptimisticConnect())
    }

    private func stopSession(markCompleted: Bool) {
        guard hasStartedSession else { return }
        hasStartedSession = false
        hasSentSceneFrame = false
        if !markCompleted {
            isRecapPresented = false
            recapReportURL = nil
        }

        speechCaptureService.cancelRecording()
        speechPlaybackService.stop()
        cameraService.stopSession()
        clearCameraUIState()

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
        isRecapPresented = false
        recapReportURL = nil
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
        suggestedGuidanceMode = nil
        dismissedSuggestedModes = []
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
            onTranscriptReady: { prompt in submitPrompt(prompt) },
            onFallbackRequested: { isTypedPromptPresented = true }
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
        if webSocketService.sendPrompt(trimmedPrompt, sessionId: sessionId, mode: selectedGuidanceMode) {
            sessionState.recordUserTurn(trimmedPrompt)
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
            cancelWarmingHint()
        case .connecting, .reconnecting:
            hasSentSceneFrame = false
            if !sessionState.isTerminal {
                sessionState.phase = .connecting
            }
            scheduleWarmingHint()
        case .disconnected where hasStartedSession && hasConnectedOnce:
            hasSentSceneFrame = false
            cancelWarmingHint()
        case .disconnected:
            hasSentSceneFrame = false
            cancelWarmingHint()
        }
    }

    private func scheduleWarmingHint() {
        guard warmingHintTask == nil, !isBackendWarming else { return }
        warmingHintTask = Task { @MainActor in
            // Render free-tier spin-up is ~15–25s. Anything past ~2.5s of
            // "connecting" on a cold start is almost certainly that, so we
            // surface a calmer "Waking backend…" copy to set expectations.
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled else { return }
            withAnimation { isBackendWarming = true }
        }
    }

    private func cancelWarmingHint() {
        warmingHintTask?.cancel()
        warmingHintTask = nil
        if isBackendWarming {
            withAnimation { isBackendWarming = false }
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
            updateSuggestedMode(from: response)
            let annotations = response.annotations?.map { Annotation(from: $0) } ?? []
            let textSource = response.text
                ?? response.nextAction
                ?? response.summary
                ?? response.recommendation
                ?? "I can see the area you mean. Hold steady and I'll guide the next small step."
            let text = GuidanceTextSanitizer.userFacing(textSource)
            let nextAction = response.nextAction?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? response.recommendation?.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = response.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            sessionState.didReceiveResponse(
                newAnnotations: annotations,
                text: text,
                nextAction: nextAction?.isEmpty == true ? nil : nextAction,
                needsCloserFrame: response.needsCloserFrame ?? false,
                followUpPrompts: response.followUpPrompts ?? [],
                confidence: GuidanceConfidence(rawValue: response.confidence?.lowercased() ?? "") ?? .medium,
                summary: summary?.isEmpty == true ? nil : summary,
                taskState: response.taskState
            )
            speechPlaybackService.speak(text, audioBase64: response.audio) {
                maybeStartHandsFreeListening()
            }
        }
    }

    private func autoListen() {
        guard canAutomaticallyListen else { return }
        speechCaptureService.startListening(
            onTranscriptReady: { prompt in submitPrompt(prompt) },
            onFallbackRequested: { }
        )
    }

    private func updateConversationMode(_ isEnabled: Bool) {
        conversationMode = isEnabled
        if isEnabled { maybeStartHandsFreeListening() }
    }

    private func setSelectedGuidanceMode(_ mode: GuidanceMode) {
        storedGuidanceModeRawValue = mode.rawValue
        if suggestedGuidanceMode == mode || mode != .general {
            suggestedGuidanceMode = nil
        }
    }

    private func dismissSuggestedMode(_ mode: GuidanceMode) {
        dismissedSuggestedModes.insert(mode)
        if suggestedGuidanceMode == mode { suggestedGuidanceMode = nil }
    }

    private func updateSuggestedMode(from response: WebSocketService.IncomingResponse) {
        let responseMode = GuidanceMode.resolved(rawValue: response.mode)
        guard selectedGuidanceMode == .general,
              responseMode == .general,
              let rawSuggestedMode = response.suggestedMode,
              let suggestedMode = GuidanceMode(rawValue: rawSuggestedMode),
              suggestedMode != .general,
              !dismissedSuggestedModes.contains(suggestedMode) else {
            suggestedGuidanceMode = nil
            return
        }
        suggestedGuidanceMode = suggestedMode
    }

    private func maybeStartHandsFreeListening() {
        guard conversationMode else { return }
        autoListen()
    }

    private var canAutomaticallyListen: Bool {
        guard guidanceReadiness.canInteract,
              !speechCaptureService.isRecording,
              !speechPlaybackService.isSpeaking,
              sessionState.overlay == nil else { return false }
        if case .active(.processing) = sessionState.phase { return false }
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
        if canInteractWithGuidance { return "Continue" }
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

    // MARK: - Camera Gesture Handlers

    private func handlePinchScale(_ scale: CGFloat, phase: PinchGesturePhase) {
        switch phase {
        case .began:
            // Snapshot the current zoom so subsequent scale deltas multiply correctly.
            pinchBaseZoom = cameraService.zoomFactor
            cameraService.applyZoomScale(scale, base: pinchBaseZoom, settle: false)
        case .changed:
            cameraService.applyZoomScale(scale, base: pinchBaseZoom, settle: false)
        case .ended:
            cameraService.applyZoomScale(scale, base: pinchBaseZoom, settle: true)
        }
        showZoomHUD()
    }

    private func handleTapToFocus(_ normalized: CGPoint, viewPoint: CGPoint) {
        guard hasStartedSession else { return }
        cameraService.focus(at: normalized)
        focusReticlePoint = viewPoint
        focusReticleToken &+= 1 // triggers re-animation even if point is identical
        isExposureLocked = false
        focusReticleClearItem?.cancel()
        let work = DispatchWorkItem {
            // Only clear if no newer tap arrived
            focusReticlePoint = nil
        }
        focusReticleClearItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    private func handleDoubleTapZoom() {
        guard hasStartedSession else { return }
        cameraService.cycleZoomSwitchPoint()
        showZoomHUD()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func handleLongPressLock() {
        guard hasStartedSession else { return }
        cameraService.lockFocusAndExposure()
        isExposureLocked = true
        // Paint the reticle at screen-center as a persistent lock indicator.
        focusReticleClearItem?.cancel()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showGuidanceToast("AE/AF locked. Tap anywhere to refocus.")
    }

    private func showZoomHUD() {
        withAnimation { zoomHUDVisible = true }
        zoomHUDWorkItem?.cancel()
        let work = DispatchWorkItem {
            withAnimation { zoomHUDVisible = false }
        }
        zoomHUDWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Clear any transient camera overlays — called when the session stops
    /// so a stale reticle or HUD doesn't linger on the next start.
    private func clearCameraUIState() {
        focusReticleClearItem?.cancel()
        focusReticleClearItem = nil
        focusReticlePoint = nil
        zoomHUDWorkItem?.cancel()
        zoomHUDWorkItem = nil
        zoomHUDVisible = false
        isTorchSliderVisible = false
        isExposureLocked = false
    }

    private func readinessTitle(for readiness: GuidanceInputReadiness) -> String {
        if speechCaptureService.isRecording { return "Listening to you" }
        switch readiness {
        case .sessionUnavailable: return "Session not ready"
        case .waitingForConnection: return "Connecting"
        case .waitingForSceneFrame: return "Need a closer frame"
        case .ready:
            if speechPlaybackService.isSpeaking { return "Speaking guidance" }
            if case .active(.processing) = sessionState.phase { return "Thinking" }
            return "Ready to answer"
        }
    }

    private var providerColor: Color {
        guard let health = backendConfiguration.backendHealth else { return .yellow }
        switch health.effectiveAvailability {
        case "live": return .green
        case "degraded": return .orange
        case "unavailable": return .red
        default: return health.isLiveReady ? .green : .yellow
        }
    }

    private func providerLineText(providerState: String, hint: String?) -> String {
        if let hint, !hint.isEmpty { return hint }
        return providerState
    }

    private func frameLineText() -> String {
        if hasSentSceneFrame { return "Camera frame is flowing to FixWise." }
        if case .connecting = sessionState.phase { return "Waiting for connection." }
        if case .active(.processing) = sessionState.phase { return "Using the latest frame." }
        if guidanceReadiness == .waitingForSceneFrame { return "Hold the phone closer." }
        return guidanceReadiness.bannerText
    }

    private func opticsLineText() -> String {
        var parts: [String] = []
        parts.append(String(format: "%.1fx", cameraService.zoomFactor))
        if cameraService.stabilizationActive {
            parts.append("stab: \(cameraService.stabilizationMode)")
        }
        if cameraService.hasHDR { parts.append("HDR") }
        if cameraService.lowLightBoostActive { parts.append("low-light boost") }
        if cameraService.autoTorchEnabled { parts.append("auto-flash") }
        else if cameraService.torchOn { parts.append("flash \(Int(cameraService.torchLevel * 100))%") }
        if isExposureLocked { parts.append("AE/AF locked") }
        return parts.joined(separator: " · ")
    }

    private func voiceLineText() -> String {
        if speechCaptureService.isRecording {
            let transcript = speechCaptureService.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return transcript.isEmpty ? "Listening for your question." : "Hearing: \(transcript)"
        }
        if speechPlaybackService.isSpeaking { return "Speaking, then listening again." }
        return conversationMode ? "Hands-free conversation is on." : "Tap Talk or Type when ready."
    }
}

// MARK: - Session Recap View

private struct SessionRecapView: View {
    @Environment(\.dismiss) private var dismiss

    let isGuestSession: Bool
    let summary: String
    let nextAction: String?
    let reportURL: URL?
    let guidanceConfidence: GuidanceConfidence
    let followUpPrompts: [String]
    let onOpenHistory: () -> Void
    let onStartAnotherSession: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    summaryCard

                    if let nextAction, !nextAction.isEmpty {
                        recapCard(
                            title: "Next action",
                            systemImage: "arrow.forward.circle.fill",
                            accent: .green,
                            text: nextAction
                        )
                    }

                    recapMetrics
                    followUpSection
                    reportSection
                    startAgainButton
                }
                .padding(20)
                .padding(.top, 6)
            }
            .background {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.08, blue: 0.14),
                        Color(red: 0.09, green: 0.13, blue: 0.18),
                        Color.black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
            .navigationTitle("Session Recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Session complete")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Text(isGuestSession ? "Guest mode" : "Signed-in account")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }

            Text("FixWise captured the result and is ready for the next round.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private var summaryCard: some View {
        recapCard(title: "Summary", systemImage: "text.alignleft", accent: .orange, text: summary)
    }

    private var recapMetrics: some View {
        HStack(spacing: 10) {
            metricPill(title: "Confidence", value: guidanceConfidence.rawValue.capitalized)
            metricPill(title: "Follow-ups", value: "\(followUpPrompts.count)")
        }
    }

    private var followUpSection: some View {
        guard !followUpPrompts.isEmpty else {
            return AnyView(EmptyView())
        }

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                Text("Suggested follow-ups")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.72))

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(followUpPrompts, id: \.self) { prompt in
                            Text(prompt)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .glassEffect(.regular, in: .capsule)
                        }
                    }
                }
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        )
    }

    private var reportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isGuestSession ? "Guest sessions do not sync a report." : "Report")
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.72))

            if isGuestSession {
                Text("Switch to a FixWise account for history and reports across devices.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
            } else if let reportURL {
                Link(destination: reportURL) {
                    Label("Open Report", systemImage: "doc.richtext")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    dismiss()
                    onOpenHistory()
                } label: {
                    Label("Open History", systemImage: "tray.full")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var startAgainButton: some View {
        Button {
            dismiss()
            onStartAnotherSession()
        } label: {
            Label("Start Another Session", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func recapCard(
        title: String,
        systemImage: String,
        accent: Color,
        text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(accent)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }

            Text(text)
                .font(.body)
                .foregroundStyle(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.white.opacity(0.68))
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

// ARViewContainer, AnnotationOverlayView, ScanLineView, CornerBracketsView
// and Color(hex:) are defined in AROverlayViews.swift
