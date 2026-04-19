import AVFoundation
import Foundation

@MainActor
final class SpeechPlaybackService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var audioPlayer: AVAudioPlayer?
    private var remoteFallbackText: String?
    private var completionHandler: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, audioBase64: String? = nil, onFinished: (() -> Void)? = nil) {
        stopCurrentPlayback()

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        completionHandler = onFinished

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[SpeechPlayback] Audio session error: \(error.localizedDescription)")
        }

        if playRemoteAudio(from: audioBase64, fallbackText: normalized) {
            return
        }

        speakSynthesizedText(normalized)
    }

    private func speakSynthesizedText(_ normalized: String) {
        guard !normalized.isEmpty else {
            completePlayback()
            return
        }

        let utterance = AVSpeechUtterance(string: normalized)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.50
        utterance.pitchMultiplier = 1.05
        utterance.preUtteranceDelay = 0.1
        currentUtterance = utterance
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        stopCurrentPlayback()
    }

    private func stopCurrentPlayback() {
        currentUtterance = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        audioPlayer?.stop()
        audioPlayer = nil
        remoteFallbackText = nil
        isSpeaking = false
        completionHandler = nil
    }

    @discardableResult
    private func playRemoteAudio(from audioBase64: String?, fallbackText: String) -> Bool {
        let normalized = audioBase64?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalized.isEmpty,
              let data = Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters]),
              !data.isEmpty,
              let player = try? AVAudioPlayer(data: data) else {
            return false
        }

        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player
        remoteFallbackText = fallbackText
        isSpeaking = true
        if player.play() {
            return true
        }

        audioPlayer = nil
        remoteFallbackText = nil
        isSpeaking = false
        return false
    }

    private func fallbackToSynthesizedTextAfterRemoteAudioFailure() {
        audioPlayer = nil
        isSpeaking = false
        let fallbackText = remoteFallbackText
        remoteFallbackText = nil
        speakSynthesizedText(fallbackText ?? "")
    }

    private func completePlayback() {
        isSpeaking = false
        currentUtterance = nil
        audioPlayer = nil
        remoteFallbackText = nil
        completionHandler?()
        completionHandler = nil
    }
}

extension SpeechPlaybackService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard currentUtterance === utterance else { return }
            completePlayback()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard currentUtterance === utterance else { return }
            isSpeaking = false
            currentUtterance = nil
            completionHandler = nil
        }
    }
}

extension SpeechPlaybackService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard audioPlayer === player else { return }
            if !flag {
                fallbackToSynthesizedTextAfterRemoteAudioFailure()
                return
            }
            completePlayback()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            guard audioPlayer === player else { return }
            fallbackToSynthesizedTextAfterRemoteAudioFailure()
        }
    }
}
