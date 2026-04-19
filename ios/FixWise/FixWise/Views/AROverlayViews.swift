import ARKit
import SceneKit
import SwiftUI

// MARK: - Scan Line Effect (Enhanced)

/// Animated dual-gradient scan line with glow trail shown while AI is analyzing.
struct ScanLineView: View {
    let isActive: Bool

    @State private var offset: CGFloat = 0
    @State private var shimmerPhase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            if isActive {
                ZStack {
                    // Glow trail behind scan line
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, .cyan.opacity(0.15), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: 60)
                        .blur(radius: 12)
                        .offset(y: offset)

                    // Primary scan line with iridescent shimmer
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, .mint.opacity(0.4), .cyan, .cyan.opacity(0.9), .mint.opacity(0.4), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 2)
                        .shadow(color: .cyan.opacity(0.8), radius: 10)
                        .shadow(color: .cyan.opacity(0.4), radius: 20)
                        .offset(y: offset)

                    // Shimmer highlight on scan line
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.9), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 80, height: 2)
                        .offset(x: shimmerPhase * geo.size.width - 40, y: offset)
                        .blendMode(.plusLighter)
                }
                .onAppear {
                    offset = 0
                    withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                        offset = geo.size.height
                    }
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                        shimmerPhase = 1.0
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Corner Brackets (Enhanced)

/// Glowing animated corner brackets with breathing pulse.
struct CornerBracketsView: View {
    let isActive: Bool

    @State private var opacity: Double = 0.4
    @State private var scale: CGFloat = 1.0

    private let bracketLength: CGFloat = 34
    private let bracketThickness: CGFloat = 2.5
    private let inset: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            if isActive {
                let w = geo.size.width
                let h = geo.size.height

                ZStack {
                    bracket(at: CGPoint(x: inset, y: inset), hDir: 1, vDir: 1)
                    bracket(at: CGPoint(x: w - inset, y: inset), hDir: -1, vDir: 1)
                    bracket(at: CGPoint(x: inset, y: h - inset), hDir: 1, vDir: -1)
                    bracket(at: CGPoint(x: w - inset, y: h - inset), hDir: -1, vDir: -1)
                }
                .scaleEffect(scale)
            }
        }
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                opacity = 0.95
                scale = 1.02
            }
        }
        .allowsHitTesting(false)
    }

    private func bracket(at origin: CGPoint, hDir: CGFloat, vDir: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: origin.x + hDir * bracketLength, y: origin.y))
            path.addLine(to: origin)
            path.addLine(to: CGPoint(x: origin.x, y: origin.y + vDir * bracketLength))
        }
        .stroke(
            LinearGradient(
                colors: [.cyan, .mint],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            style: StrokeStyle(lineWidth: bracketThickness, lineCap: .round, lineJoin: .round)
        )
        .shadow(color: .cyan.opacity(0.7), radius: 6)
    }
}

// MARK: - Annotation Overlay (Enhanced)

struct AnnotationOverlayView: View {
    let annotations: [Annotation]

    var body: some View {
        GeometryReader { geometry in
            ForEach(annotations) { annotation in
                annotationView(for: annotation, in: geometry.size)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.3)
                                .combined(with: .opacity)
                                .combined(with: .offset(y: 10)),
                            removal: .opacity.combined(with: .scale(scale: 1.15))
                        )
                    )
            }
        }
        .animation(.spring(response: 0.55, dampingFraction: 0.68), value: annotations.map(\.id))
    }

    @ViewBuilder
    private func annotationView(for annotation: Annotation, in size: CGSize) -> some View {
        switch annotation.type {
        case .circle:
            if let x = annotation.x, let y = annotation.y {
                PulsingCircleAnnotation(
                    x: CGFloat(x), y: CGFloat(y),
                    radius: CGFloat(annotation.radius ?? 0.05),
                    color: Color(hex: annotation.color) ?? .orange,
                    label: annotation.label,
                    size: size
                )
            }

        case .label:
            if let x = annotation.x, let y = annotation.y {
                GlassFloatingLabel(
                    text: annotation.label,
                    color: Color(hex: annotation.color) ?? .orange,
                    position: CGPoint(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height)
                )
            }

        case .arrow:
            if let from = annotation.from, let to = annotation.to {
                AnimatedArrow(
                    from: CGPoint(x: CGFloat(from.x) * size.width, y: CGFloat(from.y) * size.height),
                    to: CGPoint(x: CGFloat(to.x) * size.width, y: CGFloat(to.y) * size.height),
                    color: Color(hex: annotation.color) ?? .green,
                    label: annotation.label
                )
            }

        case .boundingBox:
            if let from = annotation.from, let to = annotation.to {
                GlowingBoundingBox(
                    from: CGPoint(x: CGFloat(from.x) * size.width, y: CGFloat(from.y) * size.height),
                    to: CGPoint(x: CGFloat(to.x) * size.width, y: CGFloat(to.y) * size.height),
                    color: Color(hex: annotation.color) ?? .yellow,
                    label: annotation.label
                )
            } else if let x = annotation.x, let y = annotation.y {
                GlassFloatingLabel(
                    text: annotation.label,
                    color: Color(hex: annotation.color) ?? .yellow,
                    position: CGPoint(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height)
                )
            }
        }
    }
}

// MARK: - Pulsing Circle (Enhanced)

private struct PulsingCircleAnnotation: View {
    let x: CGFloat
    let y: CGFloat
    let radius: CGFloat
    let color: Color
    let label: String
    let size: CGSize

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.7
    @State private var innerRotation: Double = 0
    @State private var appeared = false

    var body: some View {
        let r = radius * min(size.width, size.height)
        let pos = CGPoint(x: x * size.width, y: y * size.height)

        ZStack {
            // Outer expanding pulse ring
            Circle()
                .stroke(color.opacity(pulseOpacity), lineWidth: 2)
                .frame(width: r * 2 * pulseScale, height: r * 2 * pulseScale)
                .position(pos)

            // Secondary pulse ring (staggered)
            Circle()
                .stroke(color.opacity(pulseOpacity * 0.5), lineWidth: 1.5)
                .frame(width: r * 2 * (pulseScale * 0.7 + 0.3), height: r * 2 * (pulseScale * 0.7 + 0.3))
                .position(pos)

            // Glass ring — the main indicator
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [color, color.opacity(0.6), color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
                .frame(width: r * 2, height: r * 2)
                .shadow(color: color.opacity(0.8), radius: 8)
                .position(pos)

            // Inner glass disc (liquid glass effect)
            Circle()
                .fill(color.opacity(0.08))
                .frame(width: r * 2 - 3, height: r * 2 - 3)
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.15), lineWidth: 0.5)
                )
                .glassEffect(.regular, in: .circle)
                .frame(width: r * 2 - 3, height: r * 2 - 3)
                .position(pos)
                .opacity(0.6)

            // Rotating accent dashes around ring
            Circle()
                .trim(from: 0, to: 0.18)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: r * 2 + 10, height: r * 2 + 10)
                .rotationEffect(.degrees(innerRotation))
                .position(pos)

            Circle()
                .trim(from: 0.5, to: 0.68)
                .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: r * 2 + 10, height: r * 2 + 10)
                .rotationEffect(.degrees(innerRotation))
                .position(pos)

            // Crosshair center
            Path { path in
                let len: CGFloat = 10
                path.move(to: CGPoint(x: pos.x - len, y: pos.y))
                path.addLine(to: CGPoint(x: pos.x + len, y: pos.y))
                path.move(to: CGPoint(x: pos.x, y: pos.y - len))
                path.addLine(to: CGPoint(x: pos.x, y: pos.y + len))
            }
            .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            // Center dot
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
                .shadow(color: color, radius: 4)
                .position(pos)

            // Label floating above
            GlassFloatingLabel(
                text: label,
                color: color,
                position: CGPoint(x: pos.x, y: pos.y - r - 24)
            )
        }
        .scaleEffect(appeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) {
                appeared = true
            }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                pulseScale = 1.8
                pulseOpacity = 0.0
            }
            withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                innerRotation = 360
            }
        }
    }
}

// MARK: - Glass Floating Label

private struct GlassFloatingLabel: View {
    let text: String
    let color: Color
    let position: CGPoint

    @State private var floatOffset: CGFloat = 0
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .shadow(color: color, radius: 3)
            Text(text)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(color.opacity(0.25))
        )
        .overlay(
            Capsule()
                .stroke(color.opacity(0.6), lineWidth: 1)
        )
        .glassEffect(.regular, in: .capsule)
        .shadow(color: color.opacity(0.5), radius: 8)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .scaleEffect(appeared ? 1.0 : 0.7)
        .opacity(appeared ? 1.0 : 0.0)
        .position(x: position.x, y: position.y + floatOffset)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                appeared = true
            }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                floatOffset = -5
            }
        }
    }
}

// MARK: - Animated Arrow (Enhanced)

private struct AnimatedArrow: View {
    let from: CGPoint
    let to: CGPoint
    let color: Color
    let label: String

    @State private var trimEnd: CGFloat = 0
    @State private var pulsePhase: CGFloat = 0

    var body: some View {
        ZStack {
            // Outer glow trail
            Path { path in
                path.move(to: from)
                path.addLine(to: to)
            }
            .trim(from: 0, to: trimEnd)
            .stroke(color.opacity(0.35), style: StrokeStyle(lineWidth: 14, lineCap: .round))
            .blur(radius: 6)

            // Mid glow
            Path { path in
                path.move(to: from)
                path.addLine(to: to)
            }
            .trim(from: 0, to: trimEnd)
            .stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 7, lineCap: .round))

            // Primary arrow line with gradient
            Path { path in
                path.move(to: from)
                path.addLine(to: to)
            }
            .trim(from: 0, to: trimEnd)
            .stroke(
                LinearGradient(
                    colors: [color.opacity(0.7), color, .white, color],
                    startPoint: .init(x: from.x / 400, y: from.y / 400),
                    endPoint: .init(x: to.x / 400, y: to.y / 400)
                ),
                style: StrokeStyle(lineWidth: 4, lineCap: .round)
            )

            // Moving pulse dot along the line
            if trimEnd > 0.2 {
                let t = pulsePhase
                let px = from.x + (to.x - from.x) * t
                let py = from.y + (to.y - from.y) * t
                Circle()
                    .fill(.white)
                    .frame(width: 8, height: 8)
                    .shadow(color: color, radius: 8)
                    .shadow(color: color, radius: 12)
                    .position(x: px, y: py)
            }

            // Arrowhead
            if trimEnd > 0.9 {
                arrowHead
                    .transition(.opacity)
            }

            // Glass label floating at midpoint
            GlassFloatingLabel(
                text: label,
                color: color,
                position: CGPoint(
                    x: (from.x + to.x) / 2,
                    y: (from.y + to.y) / 2 - 22
                )
            )
            .opacity(trimEnd > 0.5 ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) {
                trimEnd = 1.0
            }
            withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false).delay(0.2)) {
                pulsePhase = 1.0
            }
        }
    }

    private var arrowHead: some View {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let arrowLength: CGFloat = 18
        let arrowAngle: CGFloat = .pi / 6

        return ZStack {
            // Arrowhead glow
            Path { path in
                let left = CGPoint(
                    x: to.x - arrowLength * cos(angle - arrowAngle),
                    y: to.y - arrowLength * sin(angle - arrowAngle)
                )
                let right = CGPoint(
                    x: to.x - arrowLength * cos(angle + arrowAngle),
                    y: to.y - arrowLength * sin(angle + arrowAngle)
                )
                path.move(to: left)
                path.addLine(to: to)
                path.addLine(to: right)
                path.closeSubpath()
            }
            .fill(color.opacity(0.4))
            .blur(radius: 4)

            // Arrowhead solid
            Path { path in
                let left = CGPoint(
                    x: to.x - arrowLength * cos(angle - arrowAngle),
                    y: to.y - arrowLength * sin(angle - arrowAngle)
                )
                let right = CGPoint(
                    x: to.x - arrowLength * cos(angle + arrowAngle),
                    y: to.y - arrowLength * sin(angle + arrowAngle)
                )
                path.move(to: left)
                path.addLine(to: to)
                path.addLine(to: right)
            }
            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            .shadow(color: color, radius: 4)
        }
    }
}

// MARK: - Glowing Bounding Box (Enhanced)

private struct GlowingBoundingBox: View {
    let from: CGPoint
    let to: CGPoint
    let color: Color
    let label: String

    @State private var glowOpacity: Double = 0.3
    @State private var dashPhase: CGFloat = 0
    @State private var appeared = false

    var body: some View {
        let rect = CGRect(
            x: min(from.x, to.x),
            y: min(from.y, to.y),
            width: abs(to.x - from.x),
            height: abs(to.y - from.y)
        )

        ZStack {
            // Liquid glass interior fill
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(glowOpacity * 0.12))
                .frame(width: rect.width, height: rect.height)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                )
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
                .frame(width: rect.width, height: rect.height)
                .opacity(0.5)
                .position(x: rect.midX, y: rect.midY)

            // Outer glow halo
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(glowOpacity * 0.6), lineWidth: 8)
                .blur(radius: 10)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Animated marching dashes
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    LinearGradient(
                        colors: [color, color.opacity(0.6), color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 2, dash: [10, 6], dashPhase: dashPhase)
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Corner brackets for emphasis
            cornerBrackets(for: rect, color: color)

            // Glass label anchored at top
            GlassFloatingLabel(
                text: label,
                color: color,
                position: CGPoint(x: rect.midX, y: rect.minY - 20)
            )
        }
        .scaleEffect(appeared ? 1.0 : 0.85)
        .opacity(appeared ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                appeared = true
            }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                glowOpacity = 0.9
            }
            withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
                dashPhase = -32
            }
        }
    }

    private func cornerBrackets(for rect: CGRect, color: Color) -> some View {
        let len: CGFloat = min(20, min(rect.width, rect.height) * 0.3)

        return Path { path in
            // Top-left
            path.move(to: CGPoint(x: rect.minX + len, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + len))
            // Top-right
            path.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
            // Bottom-left
            path.move(to: CGPoint(x: rect.minX + len, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len))
            // Bottom-right
            path.move(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        .shadow(color: color.opacity(0.8), radius: 6)
    }
}

// MARK: - Focus Reticle (Tap-to-Focus indicator)

/// Square reticle that briefly appears at the tapped point to confirm
/// focus/exposure adjustment, then fades out.
///
/// Pass a `token` that changes on every tap (even to the same point) so the
/// animation replays — SwiftUI uses `.id(token)` for the restart.
struct FocusReticleView: View {
    let position: CGPoint?
    let token: Int
    /// When true, render a "locked" style (filled corners) instead of the
    /// standard focus reticle — used when the user long-pressed to lock AE/AF.
    let isLocked: Bool

    @State private var scale: CGFloat = 1.4
    @State private var opacity: Double = 0.0

    var body: some View {
        GeometryReader { _ in
            if let position {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isLocked ? Color.orange : Color.yellow, lineWidth: 1.5)
                        .frame(width: 78, height: 78)
                        .shadow(color: (isLocked ? Color.orange : Color.yellow).opacity(0.7), radius: 6)

                    // Inner tick marks (4 sides)
                    ForEach(0..<4) { i in
                        Rectangle()
                            .fill(isLocked ? Color.orange : Color.yellow)
                            .frame(width: 1, height: 8)
                            .offset(y: -34)
                            .rotationEffect(.degrees(Double(i) * 90))
                    }

                    // Center dot — a tiny lock glyph when locked
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.orange)
                    } else {
                        Circle()
                            .fill(Color.yellow.opacity(0.8))
                            .frame(width: 4, height: 4)
                    }
                }
                .scaleEffect(scale)
                .opacity(opacity)
                .position(position)
                .onAppear { replayAnimation() }
                .id(token) // re-run animation on every new tap
            }
        }
        .allowsHitTesting(false)
    }

    private func replayAnimation() {
        scale = 1.4
        opacity = 0
        withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
            scale = 1.0
            opacity = 1.0
        }
        withAnimation(.easeIn(duration: 0.9).delay(0.6)) {
            opacity = 0
        }
    }
}

// MARK: - AR View with Plane Detection Visualization + Gestures

/// Phase of a pinch-zoom gesture. `.began` fires once when the user first
/// places two fingers down, giving the owner a chance to snapshot the
/// current zoom as the new "base" for subsequent scale deltas.
enum PinchGesturePhase {
    case began
    case changed
    case ended
}

struct ARViewContainer: UIViewRepresentable {
    let session: ARSession
    let showPlanes: Bool
    /// Called with the current pinch scale (1.0 = no change) and the gesture
    /// phase. Owner captures base zoom on `.began`, multiplies on `.changed`,
    /// and settles / snaps on `.ended`.
    var onPinchScale: ((CGFloat, PinchGesturePhase) -> Void)?
    /// Called with the tap location in normalized (0-1) AVFoundation focus-point space
    /// AND the raw tap point in view coordinates (for drawing a focus reticle).
    var onTapToFocus: ((CGPoint, CGPoint) -> Void)?
    /// Called when the user double-taps — cycles through lens switch-points.
    var onDoubleTap: (() -> Void)?
    /// Called when the user long-presses — AE/AF lock.
    var onLongPress: (() -> Void)?

    init(
        session: ARSession,
        showPlanes: Bool = true,
        onPinchScale: ((CGFloat, PinchGesturePhase) -> Void)? = nil,
        onTapToFocus: ((CGPoint, CGPoint) -> Void)? = nil,
        onDoubleTap: (() -> Void)? = nil,
        onLongPress: (() -> Void)? = nil
    ) {
        self.session = session
        self.showPlanes = showPlanes
        self.onPinchScale = onPinchScale
        self.onTapToFocus = onTapToFocus
        self.onDoubleTap = onDoubleTap
        self.onLongPress = onLongPress
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            showPlanes: showPlanes,
            onPinchScale: onPinchScale,
            onTapToFocus: onTapToFocus,
            onDoubleTap: onDoubleTap,
            onLongPress: onLongPress
        )
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        view.delegate = context.coordinator
        view.debugOptions = []

        // Pinch-to-zoom
        let pinch = UIPinchGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePinch(_:))
        )
        view.addGestureRecognizer(pinch)

        // Double-tap to cycle zoom switch-points (must be recognized before single-tap)
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)

        // Tap-to-focus (require double-tap to fail first so both can coexist)
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.numberOfTapsRequired = 1
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(tap)

        // Long-press for AE/AF lock — must require pinch to fail so the user
        // can pinch-to-zoom without accidentally locking exposure.
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.6
        longPress.allowableMovement = 8
        longPress.require(toFail: pinch)
        view.addGestureRecognizer(longPress)

        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.showPlanes = showPlanes
        context.coordinator.onPinchScale = onPinchScale
        context.coordinator.onTapToFocus = onTapToFocus
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.onLongPress = onLongPress
    }

    class Coordinator: NSObject, ARSCNViewDelegate {
        var showPlanes: Bool
        var onPinchScale: ((CGFloat, PinchGesturePhase) -> Void)?
        var onTapToFocus: ((CGPoint, CGPoint) -> Void)?
        var onDoubleTap: (() -> Void)?
        var onLongPress: (() -> Void)?
        private var planeNodes: [UUID: SCNNode] = [:]

        init(
            showPlanes: Bool,
            onPinchScale: ((CGFloat, PinchGesturePhase) -> Void)? = nil,
            onTapToFocus: ((CGPoint, CGPoint) -> Void)? = nil,
            onDoubleTap: (() -> Void)? = nil,
            onLongPress: (() -> Void)? = nil
        ) {
            self.showPlanes = showPlanes
            self.onPinchScale = onPinchScale
            self.onTapToFocus = onTapToFocus
            self.onDoubleTap = onDoubleTap
            self.onLongPress = onLongPress
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                onPinchScale?(recognizer.scale, .began)
            case .changed:
                onPinchScale?(recognizer.scale, .changed)
            case .ended, .cancelled, .failed:
                onPinchScale?(recognizer.scale, .ended)
            default:
                break
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let loc = recognizer.location(in: view)
            // AVFoundation focus points are normalized where (0, 0) = top-left in landscape right.
            // For portrait we need to swap & flip: x_norm = y / height, y_norm = 1 - x / width.
            let nx = loc.y / view.bounds.height
            let ny = 1.0 - loc.x / view.bounds.width
            onTapToFocus?(CGPoint(x: nx, y: ny), loc)
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            onDoubleTap?()
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            onLongPress?()
        }

        func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
            guard showPlanes, let planeAnchor = anchor as? ARPlaneAnchor else { return }
            let planeNode = createPlaneNode(for: planeAnchor)
            node.addChildNode(planeNode)
            planeNodes[anchor.identifier] = planeNode
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let planeAnchor = anchor as? ARPlaneAnchor,
                  let planeNode = planeNodes[anchor.identifier] else { return }
            updatePlaneNode(planeNode, for: planeAnchor)
        }

        func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
            planeNodes.removeValue(forKey: anchor.identifier)
        }

        private func createPlaneNode(for anchor: ARPlaneAnchor) -> SCNNode {
            let extent = anchor.extent
            let plane = SCNPlane(width: CGFloat(extent.x), height: CGFloat(extent.z))

            let material = SCNMaterial()
            material.diffuse.contents = createGridImage(
                color: anchor.alignment == .horizontal
                    ? UIColor.cyan.withAlphaComponent(0.10)
                    : UIColor(red: 0.0, green: 0.78, blue: 0.75, alpha: 1.0).withAlphaComponent(0.08)
            )
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            material.isDoubleSided = true
            material.emission.contents = anchor.alignment == .horizontal
                ? UIColor.cyan.withAlphaComponent(0.08)
                : UIColor(red: 0.0, green: 0.78, blue: 0.75, alpha: 1.0).withAlphaComponent(0.06)
            plane.materials = [material]

            let node = SCNNode(geometry: plane)
            node.eulerAngles.x = -.pi / 2
            node.position = SCNVector3(anchor.center.x, 0, anchor.center.z)
            node.opacity = 0
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.7
            node.opacity = 1
            SCNTransaction.commit()
            return node
        }

        private func updatePlaneNode(_ node: SCNNode, for anchor: ARPlaneAnchor) {
            guard let plane = node.geometry as? SCNPlane else { return }
            plane.width = CGFloat(anchor.extent.x)
            plane.height = CGFloat(anchor.extent.z)
            node.position = SCNVector3(anchor.center.x, 0, anchor.center.z)

            let repeatX = Float(anchor.extent.x) * 5
            let repeatZ = Float(anchor.extent.z) * 5
            plane.materials.first?.diffuse.contentsTransform = SCNMatrix4MakeScale(repeatX, repeatZ, 1)
        }

        private func createGridImage(color: UIColor) -> UIImage {
            let size: CGFloat = 64
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
            return renderer.image { ctx in
                let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
                UIColor.clear.setFill()
                ctx.fill(rect)

                color.setStroke()
                let path = UIBezierPath()
                path.lineWidth = 0.5

                let spacing: CGFloat = 16
                var x: CGFloat = 0
                while x <= size {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size))
                    x += spacing
                }
                var y: CGFloat = 0
                while y <= size {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size, y: y))
                    y += spacing
                }
                path.stroke()

                let dotSize: CGFloat = 3
                let dotRect = CGRect(
                    x: size / 2 - dotSize / 2,
                    y: size / 2 - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )
                color.withAlphaComponent(0.35).setFill()
                UIBezierPath(ovalIn: dotRect).fill()
            }
        }
    }
}

// MARK: - Color Hex Extension

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
