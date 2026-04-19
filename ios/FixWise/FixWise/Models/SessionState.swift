import Foundation

enum GuidanceMode: String, CaseIterable, Codable, Equatable, Hashable, Identifiable {
    case general
    case homeRepair = "home_repair"
    case gardening
    case gym
    case cooking
    case car
    case machines

    static let storageKey = "selectedGuidanceMode"

    var id: String { rawValue }

    static func resolved(rawValue: String?) -> GuidanceMode {
        guard let rawValue else { return .general }
        return GuidanceMode(rawValue: rawValue) ?? .general
    }

    static func storedSelection(in userDefaults: UserDefaults = .standard) -> GuidanceMode {
        resolved(rawValue: userDefaults.string(forKey: storageKey))
    }

    var title: String {
        switch self {
        case .general:
            return "General"
        case .homeRepair:
            return "Home Repair"
        case .gardening:
            return "Gardening & Plants"
        case .gym:
            return "Gym"
        case .cooking:
            return "Cooking"
        case .car:
            return "Car"
        case .machines:
            return "Machines & Tech"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "sparkles"
        case .homeRepair:
            return "wrench.and.screwdriver"
        case .gardening:
            return "leaf"
        case .gym:
            return "dumbbell"
        case .cooking:
            return "fork.knife"
        case .car:
            return "car.fill"
        case .machines:
            return "cpu"
        }
    }

    var readinessHint: String {
        switch self {
        case .general:
            return "Ask naturally about what you see, what to do next, or what looks unsafe."
        case .homeRepair:
            return "Ask about fixtures, leaks, fasteners, outlets, or the next repair step."
        case .gardening:
            return "Ask about plant health, watering, pruning, soil, or pests."
        case .gym:
            return "Ask about form, setup, range of motion, tempo, or injury risk."
        case .cooking:
            return "Ask about ingredients, doneness, timing, plating, or food safety."
        case .car:
            return "Ask about fluids, batteries, brakes, tires, or the next diagnostic step."
        case .machines:
            return "Ask about connectors, ports, panels, appliances, or tech setup."
        }
    }

    var typedPromptPlaceholder: String {
        switch self {
        case .general:
            return "What should I do next?"
        case .homeRepair:
            return "Which valve or fastener should I check next?"
        case .gardening:
            return "What do these leaves need?"
        case .gym:
            return "How does my setup or form look?"
        case .cooking:
            return "Is this cooked enough yet?"
        case .car:
            return "What should I inspect under the hood next?"
        case .machines:
            return "Which connector or panel should I focus on?"
        }
    }

    var promptExamples: [String] {
        switch self {
        case .general:
            return [
                "What am I looking at?",
                "What should I do next?",
                "Is anything unsafe here?"
            ]
        case .homeRepair:
            return [
                "Which shutoff or fastener matters here?",
                "Is this leak point or fitting the problem?",
                "What should I loosen or tighten next?"
            ]
        case .gardening:
            return [
                "Does this plant look overwatered?",
                "What should I prune first?",
                "Do you see pests or disease here?"
            ]
        case .gym:
            return [
                "How does my setup look?",
                "What should I correct before the next rep?",
                "Do you see any injury risk here?"
            ]
        case .cooking:
            return [
                "Is this ready to flip or plate?",
                "What should I cut or season next?",
                "Do you see any food safety issue here?"
            ]
        case .car:
            return [
                "What fluid or component is this?",
                "What should I inspect next under the hood?",
                "Does anything here look unsafe to touch?"
            ]
        case .machines:
            return [
                "What connector or part is this?",
                "What should I unplug or reseat next?",
                "Do you see any issue with this machine setup?"
            ]
        }
    }

    var suggestionTitle: String {
        "Looks like \(title)"
    }
}

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

enum GuidanceConfidence: String, Codable, Equatable {
    case low
    case medium
    case high
}

struct GuidanceChecklistItem: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let status: String
    let detail: String?

    init(id: String, title: String, status: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
    }

    var isActive: Bool {
        status.normalizedTaskStatus == "active"
    }

    var isComplete: Bool {
        ["done", "complete", "completed"].contains(status.normalizedTaskStatus)
    }
}

struct GuidanceDetectedComponent: Codable, Equatable, Identifiable {
    let label: String
    let kind: String
    let confidence: String
    let x: Double?
    let y: Double?

    var id: String {
        "\(kind)-\(label)"
    }
}

struct GuidanceTaskState: Codable, Equatable {
    let setupType: String
    let phase: String
    let title: String
    let checklist: [GuidanceChecklistItem]
    let visibleComponents: [GuidanceDetectedComponent]
    let troubleshootingFocus: String?

    var activeChecklistItem: GuidanceChecklistItem? {
        checklist.first(where: \.isActive)
            ?? checklist.first(where: { !$0.isComplete })
            ?? checklist.first
    }

    var completedChecklistCount: Int {
        checklist.filter(\.isComplete).count
    }

    var totalChecklistCount: Int {
        checklist.count
    }

    var setupTypeTitle: String {
        switch setupType {
        case "general_task":
            return "Guided task"
        case "home_repair":
            return "Home repair"
        case "plumbing_repair":
            return "Plumbing repair"
        case "electrical_repair":
            return "Electrical repair"
        case "plant_care":
            return "Plant care"
        case "exercise_form":
            return "Exercise form"
        case "cooking_task":
            return "Cooking"
        case "car_maintenance":
            return "Car maintenance"
        case "machine_setup":
            return "Machine setup"
        case "pc_build":
            return "PC build"
        case "display_setup":
            return "Display setup"
        case "network_setup":
            return "Network setup"
        case "peripheral_setup":
            return "Peripheral setup"
        default:
            return setupType.readableTaskLabel
        }
    }

    var phaseTitle: String {
        switch phase {
        case "identify":
            return "Identify"
        case "inspect":
            return "Inspect"
        case "prepare":
            return "Prepare"
        case "connect":
            return "Connect"
        case "act":
            return "Act"
        case "adjust":
            return "Adjust"
        case "verify":
            return "Verify"
        case "troubleshoot":
            return "Troubleshoot"
        case "complete":
            return "Complete"
        default:
            return phase.readableTaskLabel
        }
    }

    var troubleshootingTitle: String? {
        guard let troubleshootingFocus, !troubleshootingFocus.isEmpty else { return nil }
        switch troubleshootingFocus {
        case "no_display":
            return "No display"
        case "no_power":
            return "No power"
        case "not_detected":
            return "Not detected"
        case "network_issue":
            return "Network issue"
        case "safety_check":
            return "Safety check"
        case "plant_health":
            return "Plant health"
        case "form_risk":
            return "Form risk"
        case "doneness":
            return "Doneness"
        case "diagnosis":
            return "Diagnosis"
        case "repair_issue":
            return "Repair issue"
        default:
            return troubleshootingFocus.readableTaskLabel
        }
    }
}

struct ConversationTurn: Identifiable, Equatable {
    enum Role: String, Codable, Equatable {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    let text: String
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
    @Published private(set) var conversationTurns: [ConversationTurn] = []
    @Published private(set) var followUpPrompts: [String] = []
    @Published private(set) var sessionSummary: String = ""
    @Published private(set) var lastNextAction: String?
    @Published private(set) var guidanceConfidence: GuidanceConfidence = .medium
    @Published private(set) var needsCloserFrame = false
    @Published private(set) var taskState: GuidanceTaskState?

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
        conversationTurns = []
        followUpPrompts = []
        sessionSummary = ""
        lastNextAction = nil
        guidanceConfidence = .medium
        needsCloserFrame = false
        taskState = nil
        return id
    }

    func didConnect() {
        guard sessionId != nil else { return }
        lastGuidanceText = ""
        overlay = nil
        phase = .active(subState: .listening)
        if startTime == nil {
            startTime = Date()
            startTimer()
        } else if timer == nil {
            startTimer()
        }
    }

    func didStartProcessing() {
        overlay = nil
        needsCloserFrame = false
        phase = .active(subState: .processing)
    }

    func recordUserTurn(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        conversationTurns.append(.init(role: .user, text: normalized))
        trimConversationHistory()
        currentStep = max(currentStep, conversationTurns.count)
    }

    func didReceiveResponse(
        newAnnotations: [Annotation],
        text: String,
        nextAction: String? = nil,
        needsCloserFrame: Bool = false,
        followUpPrompts: [String] = [],
        confidence: GuidanceConfidence = .medium,
        summary: String? = nil,
        taskState: GuidanceTaskState? = nil
    ) {
        annotations = newAnnotations
        lastGuidanceText = text
        let trimmedNextAction = nextAction?.trimmingCharacters(in: .whitespacesAndNewlines)
        lastNextAction = trimmedNextAction?.isEmpty == false ? trimmedNextAction : nil
        self.needsCloserFrame = needsCloserFrame
        self.followUpPrompts = followUpPrompts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guidanceConfidence = confidence
        if let taskState {
            self.taskState = taskState
        }
        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedSummary, !trimmedSummary.isEmpty {
            sessionSummary = trimmedSummary
        } else if sessionSummary.isEmpty {
            sessionSummary = text
        }
        conversationTurns.append(.init(role: .assistant, text: text))
        trimConversationHistory()
        currentStep = max(currentStep, conversationTurns.count)
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
        conversationTurns = []
        followUpPrompts = []
        sessionSummary = ""
        lastNextAction = nil
        guidanceConfidence = .medium
        needsCloserFrame = false
        taskState = nil
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

    var visibleFollowUpPrompts: [String] {
        if !followUpPrompts.isEmpty {
            return followUpPrompts
        }

        if needsCloserFrame {
            return [
                "Move closer to the task",
                "Center the detail in the frame",
                "What should I zoom in on next?"
            ]
        }

        if let lastNextAction, !lastNextAction.isEmpty {
            return [
                lastNextAction,
                "Show me the next small step",
                "Is anything unsafe here?"
            ]
        }

        if conversationTurns.isEmpty {
            return [
                "What am I looking at?",
                "What should I do next?",
                "Is anything unsafe?"
            ]
        }

        return [
            "What should I do next?",
            "Give me a closer look",
            "Is anything unsafe?"
        ]
    }

    var recapSummaryText: String {
        let trimmedSummary = sessionSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            return trimmedSummary
        }
        if !lastGuidanceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lastGuidanceText
        }
        return "FixWise wrapped up the session and is ready for another live walkthrough."
    }

    var recapNextActionText: String? {
        let trimmed = lastNextAction?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
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

    private func trimConversationHistory(limit: Int = 8) {
        guard conversationTurns.count > limit else { return }
        conversationTurns = Array(conversationTurns.suffix(limit))
    }
}

extension String {
    var normalizedTaskStatus: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var readableTaskLabel: String {
        let words = replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let first = words.first else { return "" }
        return String(first).uppercased() + words.dropFirst()
    }
}
