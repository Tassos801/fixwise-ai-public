import Foundation
import ARKit
import Combine
import UIKit

/// Manages the ARSession, extracts frames, performs scene change detection,
/// and produces base64-encoded JPEG frames ready for the AI pipeline.
final class CameraService: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var isSessionRunning = false
    @Published var currentFrame: ARFrame?
    @Published var runtimeIssue: String?

    // MARK: - Configuration

    struct Config {
        var targetResolution: CGSize = CGSize(width: 384, height: 384)
        var jpegQuality: CGFloat = 0.5
        var idleFPS: Double = 1.0
        var activeFPS: Double = 2.0
        var highActivityFPS: Double = 3.0
        var skipThreshold: Float = 0.02
        var activeThreshold: Float = 0.05
        var highActivityThreshold: Float = 0.15
    }

    var config = Config()

    // MARK: - AR Session

    let arSession = ARSession()

    // MARK: - Frame Pipeline

    /// Publisher that emits base64-encoded frames at the adaptive sample rate.
    let framePublisher = PassthroughSubject<EncodedFrame, Never>()

    struct EncodedFrame {
        let base64: String
        let timestamp: TimeInterval
        let sceneDelta: Float
        let width: Int
        let height: Int
    }

    // MARK: - Private State

    private var lastCaptureTime: TimeInterval = 0
    private var lastFramePixels: [UInt8]?
    private var currentSampleInterval: TimeInterval { 1.0 / currentFPS }
    private var currentFPS: Double = 1.0
    private let ciContext = CIContext()

    private let frameProcessingQueue = DispatchQueue(
        label: "com.fixwise.frameprocessing",
        qos: .userInitiated
    )

    // MARK: - Lifecycle

    func startSession() {
        runtimeIssue = nil

        guard ARWorldTrackingConfiguration.isSupported else {
            runtimeIssue = "ARKit world tracking is not supported on this device."
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics = .smoothedSceneDepth
        }

        arSession.delegate = self
        arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true
    }

    func stopSession() {
        arSession.pause()
        isSessionRunning = false
        lastFramePixels = nil
        runtimeIssue = nil
    }

    // MARK: - Frame Encoding

    /// Extracts, resizes, and base64-encodes the current AR frame.
    /// Call this from the ARSessionDelegate or on a timer.
    func encodeFrame(_ frame: ARFrame) -> EncodedFrame? {
        let pixelBuffer = frame.capturedImage

        // Convert CVPixelBuffer to UIImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        let originalImage = UIImage(cgImage: cgImage)

        // Resize to target resolution
        let resized = resizeImage(originalImage, to: config.targetResolution)

        // Compute scene delta for adaptive sampling
        let delta = computeSceneDelta(from: resized)

        // Skip frame if delta is below threshold
        if delta < config.skipThreshold && lastFramePixels != nil {
            return nil
        }

        // Encode to JPEG base64
        guard let jpegData = resized.jpegData(compressionQuality: config.jpegQuality) else {
            return nil
        }

        let base64String = jpegData.base64EncodedString()

        // Update adaptive FPS
        currentFPS = recommendedFPS(for: delta)

        return EncodedFrame(
            base64: base64String,
            timestamp: frame.timestamp,
            sceneDelta: delta,
            width: Int(config.targetResolution.width),
            height: Int(config.targetResolution.height)
        )
    }

    // MARK: - Scene Change Detection

    /// Computes mean absolute pixel difference between current and previous frame.
    /// Returns a value 0.0 (identical) to 1.0 (completely different).
    private func computeSceneDelta(from image: UIImage) -> Float {
        guard let cgImage = image.cgImage else { return 1.0 }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = height * bytesPerRow

        var currentPixels = [UInt8](repeating: 0, count: totalBytes)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let contextRef = CGContext(
                  data: &currentPixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return 1.0
        }

        contextRef.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        defer { lastFramePixels = currentPixels }

        guard let previousPixels = lastFramePixels, previousPixels.count == totalBytes else {
            return 1.0 // First frame, treat as max change
        }

        // Sample every 16th pixel for performance (still accurate enough)
        var totalDiff: Int = 0
        let sampleStride = 16 * bytesPerPixel
        var sampleCount = 0

        for i in stride(from: 0, to: totalBytes - bytesPerPixel, by: sampleStride) {
            let rDiff = abs(Int(currentPixels[i]) - Int(previousPixels[i]))
            let gDiff = abs(Int(currentPixels[i+1]) - Int(previousPixels[i+1]))
            let bDiff = abs(Int(currentPixels[i+2]) - Int(previousPixels[i+2]))
            totalDiff += rDiff + gDiff + bDiff
            sampleCount += 1
        }

        guard sampleCount > 0 else { return 1.0 }

        // Normalize: max diff per sample is 255*3 = 765
        let avgDiff = Float(totalDiff) / Float(sampleCount) / 765.0
        return avgDiff
    }

    // MARK: - Adaptive Frame Rate

    func recommendedFPS(for delta: Float) -> Double {
        if delta > config.highActivityThreshold {
            return config.highActivityFPS
        }
        if delta > config.activeThreshold {
            return config.activeFPS
        }
        return config.idleFPS
    }

    // MARK: - Image Utilities

    private func resizeImage(_ image: UIImage, to targetSize: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

// MARK: - ARSessionDelegate

extension CameraService: ARSessionDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        guard now - lastCaptureTime >= currentSampleInterval else { return }

        frameProcessingQueue.async { [weak self] in
            guard let self else { return }

            if let encoded = self.encodeFrame(frame) {
                self.lastCaptureTime = now
                DispatchQueue.main.async {
                    self.currentFrame = frame
                }
                self.framePublisher.send(encoded)
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let message = "The AR camera session failed: \(error.localizedDescription)"
        print("[CameraService] \(message)")
        DispatchQueue.main.async {
            self.runtimeIssue = message
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        let message = "The camera session was interrupted. Hold steady while FixWise gets ready again."
        print("[CameraService] \(message)")
        DispatchQueue.main.async {
            self.runtimeIssue = message
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        print("[CameraService] AR session interruption ended, restarting...")
        DispatchQueue.main.async {
            self.runtimeIssue = nil
        }
        startSession()
    }
}
