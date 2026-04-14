import AVFoundation
import Foundation
import Speech

enum SpeechRecognitionShutdownMode: Equatable {
    case idle
    case finishing
    case canceling
}

enum SpeechRecognitionErrorPolicy {
    static func shouldIgnore(_ error: NSError, shutdownMode: SpeechRecognitionShutdownMode) -> Bool {
        if shutdownMode != .idle {
            return true
        }

        if error.domain == "kLSRErrorDomain" && error.code == 301 {
            return true
        }

        return false
    }
}

@MainActor
final class SpeechCaptureService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var lastErrorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcriptReadyHandler: ((String) -> Void)?
    private var fallbackHandler: (() -> Void)?
    private var didCompleteCurrentCapture = false
    private var shutdownMode: SpeechRecognitionShutdownMode = .idle

    /// Auto-submit timer: fires after silence
    private var silenceTimer: Timer?
    private let silenceTimeout: TimeInterval = 2.0

    func toggleRecording(
        onTranscriptReady: @escaping (String) -> Void,
        onFallbackRequested: @escaping () -> Void
    ) {
        transcriptReadyHandler = onTranscriptReady
        fallbackHandler = onFallbackRequested

        if isRecording {
            finishRecording(shouldSubmit: true)
            return
        }

        Task {
            await startRecordingIfPossible()
        }
    }

    func startListening(
        onTranscriptReady: @escaping (String) -> Void,
        onFallbackRequested: @escaping () -> Void
    ) {
        transcriptReadyHandler = onTranscriptReady
        fallbackHandler = onFallbackRequested

        guard !isRecording else { return }
        Task {
            await startRecordingIfPossible()
        }
    }

    func cancelRecording() {
        finishRecording(shouldSubmit: false)
    }

    private func startRecordingIfPossible() async {
        lastErrorMessage = nil
        transcript = ""
        didCompleteCurrentCapture = false
        shutdownMode = .idle

        guard await ensurePermissions() else {
            fallbackHandler?()
            return
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            fail(with: "Speech recognition is currently unavailable.")
            fallbackHandler?()
            return
        }

        do {
            try configureAudioSessionForRecording()
            try beginRecognition(with: speechRecognizer)
        } catch {
            fail(with: error.localizedDescription)
            fallbackHandler?()
        }
    }

    private func ensurePermissions() async -> Bool {
        let microphoneGranted = await requestMicrophonePermission()
        let speechStatus = await requestSpeechAuthorization()
        let isAuthorized = microphoneGranted && speechStatus == .authorized

        if !isAuthorized {
            lastErrorMessage = "Speech permissions were denied."
        }
        return isAuthorized
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func configureAudioSessionForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func beginRecognition(with speechRecognizer: SFSpeechRecognizer) throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionRequest = request
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.resetSilenceTimer()

                    if result.isFinal {
                        self.finishRecording(shouldSubmit: true)
                        return
                    }
                }

                if let error {
                    let nsError = error as NSError
                    if SpeechRecognitionErrorPolicy.shouldIgnore(nsError, shutdownMode: self.shutdownMode) {
                        self.resetRecognitionState()
                    } else if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1101 {
                        self.finishRecording(shouldSubmit: true)
                    } else if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        self.finishRecording(shouldSubmit: true)
                    } else {
                        self.fail(with: error.localizedDescription)
                        self.fallbackHandler?()
                    }
                }
            }
        }

        isRecording = true
        resetSilenceTimer()
    }

    // MARK: - Silence Detection

    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                let currentTranscript = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !currentTranscript.isEmpty {
                    self.finishRecording(shouldSubmit: true)
                }
            }
        }
    }

    private func finishRecording(shouldSubmit: Bool) {
        guard isRecording || recognitionTask != nil else { return }

        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isRecording = false
        shutdownMode = shouldSubmit ? .finishing : .canceling

        if shouldSubmit {
            submitTranscriptIfNeeded()
        } else {
            cleanupRecognition(shouldCancel: true)
        }
    }

    private func submitTranscriptIfNeeded() {
        guard !didCompleteCurrentCapture else { return }
        didCompleteCurrentCapture = true

        let finalTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanupRecognition(shouldCancel: false)

        guard !finalTranscript.isEmpty else {
            fallbackHandler?()
            return
        }

        transcriptReadyHandler?(finalTranscript)
    }

    private func cleanupRecognition(shouldCancel: Bool) {
        if shouldCancel {
            recognitionTask?.cancel()
        } else {
            recognitionTask?.finish()
        }
        resetRecognitionState()
        // Don't deactivate audio session — playback needs it
    }

    private func resetRecognitionState() {
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func fail(with message: String) {
        lastErrorMessage = message
        shutdownMode = .canceling
        cleanupRecognition(shouldCancel: true)
        isRecording = false
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
}
