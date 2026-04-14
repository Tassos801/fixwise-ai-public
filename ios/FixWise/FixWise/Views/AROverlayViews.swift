import ARKit
import SceneKit
import SwiftUI

// MARK: - Scan Line Effect

/// Animated horizontal scan line shown while AI is analyzing.
struct ScanLineView: View {
    let isActive: Bool

    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            if isActive {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .cyan.opacity(0.5), .cyan.opacity(0.8), .cyan.opacity(0.5), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 3)
                    .shadow(color: .cyan.opacity(0.6), radius: 8, y: 0)
                    .offset(y: offset)
                    .onAppear {
                        offset = 0
                        withAnimation(
                            .easeInOut(duration: 1.8)
                            .repeatForever(autoreverses: true)
                        ) {
                            offset = geo.size.height
                        }
                    }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Corner Brackets

/// Draws animated corner brackets around the camera viewport.
struct CornerBracketsView: View {
    let isActive: Bool

    @State private var opacity: Double = 0.4

    private let bracketLength: CGFloat = 32
    private let bracketThickness: CGFloat = 3
    private let inset: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            if isActive {
                let w = geo.size.width
                let h = geo.size.height

                // Top-left
                bracket(at: CGPoint(x: inset, y: inset), hDir: 1, vDir: 1)
                // Top-right
                bracket(at: CGPoint(x: w - inset, y: inset), hDir: -1, vDir: 1)
                // Bottom-left
                bracket(at: CGPoint(x: inset, y: h - inset), hDir: 1, vDir: -1)
                // Bottom-right
                bracket(at: CGPoint(x: w - inset, y: h - inset), hDir: -1, vDir: -1)
            }
        }
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                opacity = 0.9
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
        .stroke(Color.cyan, style: StrokeStyle(lineWidth: bracketThickness, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - Animated Annotation Overlay

struct AnnotationOverlayView: View {
    let annotations: [Annotation]

    @State private var appeared = false

    var body: some View {
        GeometryReader { geometry in
            ForEach(annotations) { annotation in
                annotationView(for: annotation, in: geometry.size)
                    .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .animation(.easeOut(duration: 0.4), value: annotations.map(\.id))
        .onAppear { appeared = true }
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
                FloatingLabel(
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
                // Fallback: model returned x/y instead of from/to — render as label
                FloatingLabel(
                    text: annotation.label,
                    color: Color(hex: annotation.color) ?? .yellow,
                    position: CGPoint(x: CGFloat(x) * size.width, y: CGFloat(y) * size.height)
                )
            }
        }
    }
}

// MARK: - Pulsing Circle

private struct PulsingCircleAnnotation: View {
    let x: CGFloat
    let y: CGFloat
    let radius: CGFloat
    let color: Color
    let label: String
    let size: CGSize

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6

    var body: some View {
        let r = radius * min(size.width, size.height)
        let pos = CGPoint(x: x * size.width, y: y * size.height)

        ZStack {
            // Outer pulse ring
            Circle()
                .stroke(color.opacity(pulseOpacity), lineWidth: 2)
                .frame(width: r * 2 * pulseScale, height: r * 2 * pulseScale)
                .position(pos)

            // Inner solid ring
            Circle()
                .stroke(color, lineWidth: 3)
                .frame(width: r * 2, height: r * 2)
                .position(pos)

            // Crosshair
            Path { path in
                let len: CGFloat = 8
                path.move(to: CGPoint(x: pos.x - len, y: pos.y))
                path.addLine(to: CGPoint(x: pos.x + len, y: pos.y))
                path.move(to: CGPoint(x: pos.x, y: pos.y - len))
                path.addLine(to: CGPoint(x: pos.x, y: pos.y + len))
            }
            .stroke(color.opacity(0.7), lineWidth: 1.5)

            // Label
            annotationLabel(label)
                .position(x: pos.x, y: pos.y - r - 18)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) {
                pulseScale = 1.6
                pulseOpacity = 0.0
            }
        }
    }
}

// MARK: - Floating Label

private struct FloatingLabel: View {
    let text: String
    let color: Color
    let position: CGPoint

    @State private var floatOffset: CGFloat = 0

    var body: some View {
        annotationLabel(text)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.85), in: Capsule())
            .shadow(color: color.opacity(0.5), radius: 6)
            .position(x: position.x, y: position.y + floatOffset)
            .onAppear {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    floatOffset = -6
                }
            }
    }
}

// MARK: - Animated Arrow

private struct AnimatedArrow: View {
    let from: CGPoint
    let to: CGPoint
    let color: Color
    let label: String

    @State private var trimEnd: CGFloat = 0

    var body: some View {
        ZStack {
            // Arrow line with draw-in animation
            Path { path in
                path.move(to: from)
                path.addLine(to: to)
            }
            .trim(from: 0, to: trimEnd)
            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))

            // Arrowhead (appears after line draws)
            if trimEnd > 0.9 {
                arrowHead
                    .transition(.opacity)
            }

            // Glow trail
            Path { path in
                path.move(to: from)
                path.addLine(to: to)
            }
            .trim(from: 0, to: trimEnd)
            .stroke(color.opacity(0.3), style: StrokeStyle(lineWidth: 10, lineCap: .round))

            annotationLabel(label)
                .background(color.opacity(0.85), in: Capsule())
                .position(
                    x: (from.x + to.x) / 2,
                    y: (from.y + to.y) / 2 - 18
                )
                .opacity(trimEnd > 0.5 ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                trimEnd = 1.0
            }
        }
    }

    private var arrowHead: some View {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let arrowLength: CGFloat = 16
        let arrowAngle: CGFloat = .pi / 6

        return Path { path in
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
    }
}

// MARK: - Glowing Bounding Box

private struct GlowingBoundingBox: View {
    let from: CGPoint
    let to: CGPoint
    let color: Color
    let label: String

    @State private var glowOpacity: Double = 0.3
    @State private var dashPhase: CGFloat = 0

    var body: some View {
        let rect = CGRect(
            x: min(from.x, to.x),
            y: min(from.y, to.y),
            width: abs(to.x - from.x),
            height: abs(to.y - from.y)
        )

        ZStack {
            // Glow fill
            Rectangle()
                .fill(color.opacity(glowOpacity * 0.15))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Animated dashed border
            Rectangle()
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 2.5, dash: [8, 6], dashPhase: dashPhase)
                )
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Solid corner brackets
            cornerBrackets(for: rect, color: color)

            // Label
            annotationLabel(label)
                .background(color.opacity(0.85), in: Capsule())
                .position(x: rect.midX, y: rect.minY - 16)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                glowOpacity = 0.8
            }
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                dashPhase = -28
            }
        }
    }

    private func cornerBrackets(for rect: CGRect, color: Color) -> some View {
        let len: CGFloat = min(16, min(rect.width, rect.height) * 0.3)

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
        .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - AR View with Plane Detection Visualization

struct ARViewContainer: UIViewRepresentable {
    let session: ARSession
    let showPlanes: Bool

    init(session: ARSession, showPlanes: Bool = true) {
        self.session = session
        self.showPlanes = showPlanes
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(showPlanes: showPlanes)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.session = session
        view.automaticallyUpdatesLighting = true
        view.rendersContinuously = true
        view.delegate = context.coordinator
        view.debugOptions = []
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.showPlanes = showPlanes
    }

    class Coordinator: NSObject, ARSCNViewDelegate {
        var showPlanes: Bool
        private var planeNodes: [UUID: SCNNode] = [:]

        init(showPlanes: Bool) {
            self.showPlanes = showPlanes
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
                    ? UIColor.cyan.withAlphaComponent(0.08)
                    : UIColor.green.withAlphaComponent(0.06)
            )
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            material.isDoubleSided = true
            plane.materials = [material]

            let node = SCNNode(geometry: plane)
            node.eulerAngles.x = -.pi / 2
            node.position = SCNVector3(anchor.center.x, 0, anchor.center.z)
            node.opacity = 0
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.5
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

                // Grid lines
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

                // Dot at center
                let dotSize: CGFloat = 3
                let dotRect = CGRect(
                    x: size / 2 - dotSize / 2,
                    y: size / 2 - dotSize / 2,
                    width: dotSize,
                    height: dotSize
                )
                color.withAlphaComponent(0.3).setFill()
                UIBezierPath(ovalIn: dotRect).fill()
            }
        }
    }
}

// MARK: - Shared Label Helper

private func annotationLabel(_ text: String) -> some View {
    Text(text)
        .font(.caption.bold())
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.72), in: Capsule())
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
