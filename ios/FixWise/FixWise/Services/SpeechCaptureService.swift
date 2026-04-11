import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechCaptureService: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published private(set) var lastErrorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var transcriptReadyHandler: ((String) -> Void)?
    private var fallbackHandler: (() -> Void)?
    private var didCompleteCurrentCapture = false

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

    func cancelRecording() {
        finishRecording(shouldSubmit: false)
    }

    private func startRecordingIfPossible() async {
        lastErrorMessage = nil
        transcript = ""
        didCompleteCurrentCapture = false

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
        try audioSession.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
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
                    if result.isFinal {
                        self.finishRecording(shouldSubmit: true)
                        return
                    }
                }

                if let error {
                    self.fail(with: error.localizedDescription)
                    self.fallbackHandler?()
                }
            }
        }

        isRecording = true
    }

    private func finishRecording(shouldSubmit: Bool) {
        guard isRecording || recognitionTask != nil else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isRecording = false

        if shouldSubmit {
            submitTranscriptIfNeeded()
        } else {
            cleanupRecognition()
        }
    }

    private func submitTranscriptIfNeeded() {
        guard !didCompleteCurrentCapture else { return }
        didCompleteCurrentCapture = true

        let finalTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanupRecognition()

        guard !finalTranscript.isEmpty else {
            fallbackHandler?()
            return
        }

        transcriptReadyHandler?(finalTranscript)
    }

    private func cleanupRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func fail(with message: String) {
        lastErrorMessage = message
        cleanupRecognition()
        isRecording = false
    }
}
