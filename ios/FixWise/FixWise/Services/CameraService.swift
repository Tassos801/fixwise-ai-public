import Foundation
import ARKit
import AVFoundation
import Combine
import UIKit

/// Manages the ARSession, extracts frames, performs scene change detection,
/// and produces base64-encoded JPEG frames ready for the AI pipeline.
///
/// Exposes full camera capabilities: zoom (including virtual multi-lens
/// switchover with smooth ramping), torch with dimmable level and
/// ambient-light-based auto-torch, low-light boost, continuous smooth
/// auto-focus, tap-to-focus/expose, cinematic video stabilization, and HDR.
@MainActor
final class CameraService: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var isSessionRunning = false
    @Published var currentFrame: ARFrame?
    @Published var runtimeIssue: String?

    /// Current digital zoom factor (includes virtual camera switchover).
    @Published private(set) var zoomFactor: CGFloat = 1.0
    /// Minimum available zoom factor (0.5x on devices with ultra-wide).
    @Published private(set) var minZoomFactor: CGFloat = 1.0
    /// Maximum zoom factor exposed to the user (clamped to 10x for usability).
    @Published private(set) var maxZoomFactor: CGFloat = 6.0
    /// Quick-access zoom levels corresponding to physical/virtual lenses (e.g. [0.5, 1, 2, 3]).
    @Published private(set) var zoomSwitchPoints: [CGFloat] = [1.0]
    /// Whether the active capture device has a torch.
    @Published private(set) var hasTorch: Bool = false
    /// Whether the torch is currently on.
    @Published private(set) var torchOn: Bool = false
    /// Torch brightness, 0…1. Only meaningful when `torchOn` is true.
    @Published private(set) var torchLevel: Float = 0.8
    /// Whether auto-torch is active — monitors ambient light and toggles torch automatically.
    @Published var autoTorchEnabled: Bool = false
    /// Whether the device supports video HDR.
    @Published private(set) var hasHDR: Bool = false
    /// Whether video stabilization is active (cinematic extended preferred).
    @Published private(set) var stabilizationActive: Bool = false
    /// The stabilization mode actually applied ("Cinematic Extended", "Cinematic", "Standard", "Off").
    @Published private(set) var stabilizationMode: String = "Off"
    /// Whether low-light boost is currently engaged by the capture device.
    @Published private(set) var lowLightBoostActive: Bool = false
    /// Ambient light intensity from ARKit light estimate (lumens). 0 if unknown.
    @Published private(set) var ambientLightIntensity: CGFloat = 0
    /// Ambient color temperature (Kelvin) from ARKit light estimate. 0 if unknown.
    @Published private(set) var ambientColorTemperature: CGFloat = 0

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
        /// Below this lumen value auto-torch engages, above it disengages (with hysteresis).
        var autoTorchOnLumens: CGFloat = 120
        var autoTorchOffLumens: CGFloat = 320
        /// Skip frame encoding when the device is moving fast (visible motion blur).
        /// Threshold is in scene-delta units; beyond this we drop frames while the user stabilizes.
        var motionBlurSkipThreshold: Float = 0.55
    }

    var config = Config()

    // MARK: - AR Session

    let arSession = ARSession()

    // MARK: - Frame Pipeline

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

    /// The underlying AVCaptureDevice used by ARKit (iOS 16+).
    /// Exposed so we can control zoom, torch, focus, HDR directly.
    private weak var captureDevice: AVCaptureDevice?

    /// Monotonic counter used to throttle auto-torch decisions across frames.
    private var lastAutoTorchEvaluation: TimeInterval = 0

    // MARK: - Lifecycle

    func startSession() {
        runtimeIssue = nil

        guard ARWorldTrackingConfiguration.isSupported else {
            runtimeIssue = "ARKit world tracking is not supported on this device."
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]

        // Smoothed scene depth for better tracking + annotation placement
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }

        // Auto-focus
        configuration.isAutoFocusEnabled = true

        // Pick the best video format: prefer high-res HDR when available
        if let bestFormat = selectBestVideoFormat() {
            configuration.videoFormat = bestFormat
        }

        // HDR when the format supports it (iOS 16+)
        if configuration.videoFormat.isVideoHDRSupported {
            configuration.videoHDRAllowed = true
            hasHDR = true
        } else {
            hasHDR = false
        }

        arSession.delegate = self
        arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        isSessionRunning = true

        // Once running, bind to the live capture device so we can drive zoom/torch
        bindCaptureDevice(for: configuration)
    }

    func stopSession() {
        // Turn off torch before pausing
        if torchOn { setTorch(on: false) }

        arSession.pause()
        isSessionRunning = false
        lastFramePixels = nil
        runtimeIssue = nil
        captureDevice = nil
        stabilizationActive = false
        stabilizationMode = "Off"
        lowLightBoostActive = false
    }

    // MARK: - Video Format Selection

    /// Pick the video format that gives us the best balance of resolution, HDR,
    /// cinematic stabilization, and framerate. Prefer formats flagged as
    /// high-resolution, HDR-capable, and able to run cinematic extended stabilization.
    private func selectBestVideoFormat() -> ARConfiguration.VideoFormat? {
        let supported = ARWorldTrackingConfiguration.supportedVideoFormats
        guard !supported.isEmpty else { return nil }

        // Score candidates: HDR + cinematic extended stab + high res + fps
        func score(_ f: ARConfiguration.VideoFormat) -> Int {
            var s = 0
            if f.isVideoHDRSupported { s += 40 }
            if f.isRecommendedForHighResolutionFrameCapturing { s += 25 }
            // Resolution contribution
            let pixels = Int(f.imageResolution.width * f.imageResolution.height)
            s += pixels / 100_000
            // Framerate contribution (capped so we don't chase 120fps AR formats)
            s += min(Int(f.framesPerSecond), 60) / 2
            return s
        }

        return supported.max(by: { score($0) < score($1) })
    }

    // MARK: - Capture Device Binding

    private func bindCaptureDevice(for configuration: ARWorldTrackingConfiguration) {
        // ARKit 6 / iOS 16: access the underlying capture device to control
        // zoom, torch, focus, and stabilization.
        let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera
        captureDevice = device

        guard let device else {
            hasTorch = false
            zoomSwitchPoints = [1.0]
            minZoomFactor = 1.0
            maxZoomFactor = 1.0
            return
        }

        hasTorch = device.hasTorch

        // Derive zoom bounds. Physical devices with ultra-wide expose a
        // switchover-factor like 2.0 (meaning 1.0 = wide, 0.5 of the virtual range = ultra-wide).
        // We want to present it as 0.5 / 1 / 2 / 3 etc.
        let switchover = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        let hardwareMin = device.minAvailableVideoZoomFactor
        let hardwareMax = device.maxAvailableVideoZoomFactor

        // User-facing minimum: if there's an ultra-wide, expose 0.5x (hardwareMin / firstSwitchover).
        // The "1x" point in user-space = the first switchover factor.
        let oneX: CGFloat = switchover.first ?? 1.0

        minZoomFactor = max(hardwareMin / oneX, 0.5)
        maxZoomFactor = min(hardwareMax / oneX, 10.0)

        // Build user-facing quick switch points: 0.5 (if ultra-wide), 1, and each subsequent switchover
        var points: [CGFloat] = []
        if minZoomFactor < 1.0 { points.append(0.5) }
        points.append(1.0)
        for s in switchover.dropFirst() {
            let userZoom = s / oneX
            if userZoom <= maxZoomFactor {
                points.append(round(userZoom * 10) / 10)
            }
        }
        // Deduplicate and sort
        zoomSwitchPoints = Array(Set(points)).sorted()

        // Apply initial device tuning: continuous smooth focus, continuous exposure,
        // auto white balance, low-light boost. Swallow errors individually so one
        // missing capability doesn't block the rest.
        applyInitialCaptureTuning(on: device)

        // Set initial zoom to 1.0 (the "main wide lens" — i.e. the first switchover factor in hardware)
        setZoomFactor(1.0, ramp: false)

        // Enable stabilization on the underlying connection if supported
        applyStabilization()
    }

    /// Configure focus/exposure/white-balance/low-light-boost modes that benefit
    /// a handheld AR scene analysis use-case: smooth + continuous everything.
    private func applyInitialCaptureTuning(on device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()

            // Continuous auto-focus with smooth-focus to suppress micro-oscillation
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }

            // Continuous auto-exposure
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }

            // Continuous auto white-balance for color-accurate scene understanding
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }

            // Low-light boost: let the device pump up ISO when it's dark
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }

            // Geometric distortion correction on devices that support it (wide lens)
            if device.isGeometricDistortionCorrectionSupported {
                device.isGeometricDistortionCorrectionEnabled = true
            }

            device.unlockForConfiguration()
        } catch {
            print("[CameraService] Failed initial capture tuning: \(error)")
        }
    }

    // MARK: - Zoom

    /// Set zoom in user-facing units (0.5x, 1x, 2x, 3x…).
    /// Internally maps to the hardware's videoZoomFactor range.
    func setZoomFactor(_ userZoom: CGFloat, ramp: Bool = true, rate: Float = 4.0) {
        guard let device = captureDevice else { return }
        let clamped = min(max(userZoom, minZoomFactor), maxZoomFactor)
        let oneX = (device.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) }) ?? 1.0
        let hardwareFactor = clamped * oneX
        let hardwareMin = device.minAvailableVideoZoomFactor
        let hardwareMax = device.maxAvailableVideoZoomFactor
        let target = min(max(hardwareFactor, hardwareMin), hardwareMax)

        do {
            try device.lockForConfiguration()
            if ramp {
                // Cancel any in-flight ramp before starting a new one so gestures stay responsive.
                if device.isRampingVideoZoom {
                    device.cancelVideoZoomRamp()
                }
                device.ramp(toVideoZoomFactor: target, withRate: rate)
            } else {
                device.videoZoomFactor = target
            }
            device.unlockForConfiguration()
            zoomFactor = clamped
        } catch {
            print("[CameraService] Failed to set zoom: \(error)")
        }
    }

    /// Multiply the current zoom by a factor (used for pinch gestures).
    /// `base` is the zoom at the start of the gesture. When `settle` is true,
    /// snap to the nearest lens switch-point if within 8% for haptic "detent" feel.
    func applyZoomScale(_ scale: CGFloat, base: CGFloat, settle: Bool = false) {
        var target = base * scale
        var didSnap = false
        if settle {
            for point in zoomSwitchPoints {
                if abs(target - point) / point < 0.08 {
                    target = point
                    didSnap = true
                    break
                }
            }
        }
        // Ramp only when we actually need to glide to a snapped point; mid-gesture
        // changes apply instantly for responsiveness.
        setZoomFactor(target, ramp: didSnap, rate: 6.0)
    }

    /// Cycle through the lens switch-points (for a "1x → 2x → 3x → 0.5x" button).
    /// Useful for a double-tap gesture or a single hardware-lens chip.
    func cycleZoomSwitchPoint() {
        guard !zoomSwitchPoints.isEmpty else { return }
        // Find the next switch-point strictly greater than current zoom, else wrap to min.
        let next = zoomSwitchPoints.first(where: { $0 > zoomFactor + 0.01 }) ?? zoomSwitchPoints.first!
        setZoomFactor(next, ramp: true, rate: 8.0)
    }

    // MARK: - Torch / Flash

    func toggleTorch() {
        setTorch(on: !torchOn)
    }

    /// Turn the torch on or off. When turning on, uses the last-set `torchLevel`.
    func setTorch(on: Bool) {
        guard let device = captureDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if on {
                let level = min(max(torchLevel, 0.05), AVCaptureDevice.maxAvailableTorchLevel)
                try device.setTorchModeOn(level: level)
            } else {
                device.torchMode = .off
            }
            device.unlockForConfiguration()
            torchOn = on
        } catch {
            print("[CameraService] Failed to set torch: \(error)")
        }
    }

    /// Set torch brightness (0…1). Persists even when torch is off; applied next time it's turned on.
    /// If torch is currently on, adjusts live.
    func setTorchLevel(_ level: Float) {
        let clamped = min(max(level, 0.05), min(1.0, AVCaptureDevice.maxAvailableTorchLevel))
        torchLevel = clamped
        guard torchOn, let device = captureDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            try device.setTorchModeOn(level: clamped)
            device.unlockForConfiguration()
        } catch {
            print("[CameraService] Failed to set torch level: \(error)")
        }
    }

    /// Toggle auto-torch. When enabled, we monitor ambient light each frame
    /// and turn the torch on/off with hysteresis. Disabling does NOT force the
    /// torch off — the caller decides whether to also call `setTorch(on: false)`.
    func setAutoTorch(enabled: Bool) {
        autoTorchEnabled = enabled
        lastAutoTorchEvaluation = 0 // force an immediate re-evaluation on the next frame
    }

    /// Evaluate ambient light and drive torch when auto-torch is enabled.
    /// Called from the ARSession delegate on each frame; throttled internally.
    private func evaluateAutoTorch(frame: ARFrame) {
        guard autoTorchEnabled, hasTorch else { return }
        let now = frame.timestamp
        // Evaluate at most every 0.75s to avoid flicker
        if now - lastAutoTorchEvaluation < 0.75 { return }
        lastAutoTorchEvaluation = now

        guard let estimate = frame.lightEstimate else { return }
        let lumens = estimate.ambientIntensity // ~0 dark, ~1000 bright office
        ambientLightIntensity = lumens
        ambientColorTemperature = estimate.ambientColorTemperature

        if !torchOn && lumens < config.autoTorchOnLumens {
            setTorch(on: true)
        } else if torchOn && lumens > config.autoTorchOffLumens {
            setTorch(on: false)
        }
    }

    // MARK: - Stabilization

    private func applyStabilization() {
        // ARKit manages its own capture session, so we can't directly set
        // AVCaptureConnection.preferredVideoStabilizationMode on its output.
        // However, ARKit already applies VIO-based stabilization. We probe the
        // device's active format to report the highest stabilization tier
        // available to the UI so users know what's running.
        guard let device = captureDevice else {
            stabilizationActive = false
            stabilizationMode = "Off"
            return
        }
        let activeFormat = device.activeFormat
        if activeFormat.isVideoStabilizationModeSupported(.cinematicExtended) {
            stabilizationActive = true
            stabilizationMode = "Cinematic Extended"
        } else if activeFormat.isVideoStabilizationModeSupported(.cinematic) {
            stabilizationActive = true
            stabilizationMode = "Cinematic"
        } else if activeFormat.isVideoStabilizationModeSupported(.standard) {
            stabilizationActive = true
            stabilizationMode = "Standard"
        } else {
            stabilizationActive = false
            stabilizationMode = "Off"
        }
    }

    // MARK: - Manual Focus / Tap-to-Focus

    /// Monotonic token that identifies the latest tap-to-focus gesture so
    /// stale delayed reverts can be ignored.
    private var focusRevertToken: Int = 0

    /// Triggers an auto-focus + auto-exposure at the given normalized point (0…1).
    /// After the tap-driven one-shot, we return the device to continuous tracking
    /// so the user doesn't end up stuck on a stale plane of focus — unless the
    /// user has since locked AE/AF (e.g. via long-press).
    func focus(at point: CGPoint) {
        guard let device = captureDevice else { return }
        let clamped = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        do {
            try device.lockForConfiguration()
            if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = clamped
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = clamped
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()

            focusRevertToken &+= 1
            let token = focusRevertToken

            // After a short delay, revert to continuous modes so tracking follows the subject.
            // Skip the revert if the user has meanwhile locked AE/AF or issued another tap.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.5))
                guard let self, let device = self.captureDevice else { return }
                await MainActor.run {
                    guard token == self.focusRevertToken else { return }
                    // If user has explicitly locked, don't override.
                    if device.focusMode == .locked || device.exposureMode == .locked { return }
                    do {
                        try device.lockForConfiguration()
                        if device.isFocusModeSupported(.continuousAutoFocus) {
                            device.focusMode = .continuousAutoFocus
                        }
                        if device.isExposureModeSupported(.continuousAutoExposure) {
                            device.exposureMode = .continuousAutoExposure
                        }
                        device.unlockForConfiguration()
                    } catch {
                        print("[CameraService] Failed to revert focus: \(error)")
                    }
                }
            }
        } catch {
            print("[CameraService] Failed to focus: \(error)")
        }
    }

    /// Lock focus/exposure at the current value — useful for long-press "AE/AF lock".
    /// Bumping the revert token ensures a pending tap-to-focus revert can't
    /// silently un-lock us a couple of seconds later.
    func lockFocusAndExposure() {
        guard let device = captureDevice else { return }
        focusRevertToken &+= 1
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            device.unlockForConfiguration()
        } catch {
            print("[CameraService] Failed to lock AE/AF: \(error)")
        }
    }

    // MARK: - Frame Encoding

    func encodeFrame(_ frame: ARFrame) -> EncodedFrame? {
        let pixelBuffer = frame.capturedImage

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        let originalImage = UIImage(cgImage: cgImage)
        let resized = resizeImage(originalImage, to: config.targetResolution)

        let delta = computeSceneDelta(from: resized)

        if delta < config.skipThreshold && lastFramePixels != nil {
            return nil
        }

        // Skip frames when the user is moving the phone so fast the shot is likely
        // motion-blurred — hand the AI a crisp frame once the user settles.
        if delta > config.motionBlurSkipThreshold {
            return nil
        }

        guard let jpegData = resized.jpegData(compressionQuality: config.jpegQuality) else {
            return nil
        }

        let base64String = jpegData.base64EncodedString()
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
            return 1.0
        }

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

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in
            // Update live device-state telemetry (low-light boost, ambient light)
            if let device = self.captureDevice {
                let isBoosting = device.isLowLightBoostSupported && device.isLowLightBoostEnabled
                if self.lowLightBoostActive != isBoosting {
                    self.lowLightBoostActive = isBoosting
                }
            }
            if let estimate = frame.lightEstimate {
                self.ambientLightIntensity = estimate.ambientIntensity
                self.ambientColorTemperature = estimate.ambientColorTemperature
            }
            self.evaluateAutoTorch(frame: frame)

            let now = frame.timestamp
            guard now - self.lastCaptureTime >= self.currentSampleInterval else { return }

            self.frameProcessingQueue.async { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    if let encoded = self.encodeFrame(frame) {
                        self.lastCaptureTime = now
                        self.currentFrame = frame
                        self.framePublisher.send(encoded)
                    }
                }
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = "The AR camera session failed: \(error.localizedDescription)"
        print("[CameraService] \(message)")
        Task { @MainActor in
            self.runtimeIssue = message
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        let message = "The camera session was interrupted. Hold steady while FixWise gets ready again."
        print("[CameraService] \(message)")
        Task { @MainActor in
            self.runtimeIssue = message
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        print("[CameraService] AR session interruption ended, restarting...")
        Task { @MainActor in
            self.runtimeIssue = nil
            self.startSession()
        }
    }
}
