import Foundation

/// State machine for a FixWise guidance session.
enum SessionPhase: Equatable {
    case idle
    case connecting
    case active(subState: ActiveSubState)
    case ending
    case completed(reportURL: URL?)
    case error(String)

    enum ActiveSubState: Equatable {
        case listening    // Wake-word detection active, waiting for user
        case processing   // AI is analyzing frame/audio
        case responding   // AI is speaking / annotations displayed
    }
}

enum SessionOverlay: Equatable {
    case safety(String)
    case error(String)
}

/// Manages session lifecycle and metadata.
@MainActor
final class SessionState: ObservableObject {

    @Published var phase: SessionPhase = .idle
    @Published var sessionId: String?
    @Published var currentStep: Int = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var annotations: [Annotation] = []
    @Published var lastGuidanceText: String = ""
    @Published var overlay: SessionOverlay?

    private var startTime: Date?
    private var timer: Timer?

    func startSession() -> String {
        let id = UUID().uuidString
        sessionId = id
        phase = .connecting
        currentStep = 0
        annotations = []
        lastGuidanceText = ""
        overlay = nil
        return id
    }

    func didConnect() {
        guard sessionId != nil else { return }
        overlay = nil
        phase = .active(subState: .listening)
        if startTime == nil {
            startTime = Date()
            startTimer()
        }
    }

    func didStartProcessing() {
        overlay = nil
        phase = .active(subState: .processing)
    }

    func didReceiveResponse(step: Int, newAnnotations: [Annotation], text: String) {
        currentStep = step
        annotations = newAnnotations
        lastGuidanceText = text
        overlay = nil
        phase = .active(subState: .responding)

        // Return to listening after annotations are shown
        Task {
            try? await Task.sleep(for: .seconds(2))
            if case .active(.responding) = phase {
                phase = .active(subState: .listening)
            }
        }
    }

    func endSession(reportURL: URL? = nil) {
        overlay = nil
        phase = .ending
        stopTimer()

        // Transition to completed after brief delay (for cleanup)
        Task {
            try? await Task.sleep(for: .seconds(1))
            phase = .completed(reportURL: reportURL)
        }
    }

    func reset() {
        phase = .idle
        sessionId = nil
        currentStep = 0
        elapsedTime = 0
        annotations = []
        lastGuidanceText = ""
        overlay = nil
        startTime = nil
        stopTimer()
    }

    func handleError(_ message: String, shouldStopTimer: Bool = true) {
        lastGuidanceText = message
        overlay = .error(message)
        phase = .error(message)
        if shouldStopTimer {
            stopTimer()
        }
    }

    func handleSafetyNotice(_ message: String) {
        lastGuidanceText = message
        overlay = .safety(message)
        phase = .active(subState: .responding)
    }

    func resumeListening() {
        overlay = nil
        phase = .active(subState: .listening)
    }

    var isTerminal: Bool {
        switch phase {
        case .ending, .completed:
            return true
        default:
            return false
        }
    }

    // MARK: - Timer

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
