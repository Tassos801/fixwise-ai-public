import Foundation
import simd

/// Annotation types the AI can return for AR overlay rendering.
enum AnnotationType: String, Codable {
    case circle
    case arrow
    case label
    case boundingBox = "bounding_box"
}

/// A single annotation to render in AR space.
struct Annotation: Identifiable, Codable {
    let id: UUID
    let type: AnnotationType
    let label: String
    let color: String

    // For circle and label types
    let x: Float?
    let y: Float?
    let radius: Float?

    // For arrow and bounding box types
    let from: NormalizedPoint?
    let to: NormalizedPoint?

    struct NormalizedPoint: Codable {
        let x: Float
        let y: Float
    }

    init(from wsAnnotation: WebSocketService.AnnotationData) {
        self.id = UUID()
        self.type = AnnotationType(rawValue: wsAnnotation.type) ?? .label
        self.label = wsAnnotation.label
        self.color = wsAnnotation.color ?? "#FF6B35"
        self.x = wsAnnotation.x
        self.y = wsAnnotation.y
        self.radius = wsAnnotation.radius
        self.from = wsAnnotation.from.map { NormalizedPoint(x: $0.x, y: $0.y) }
        self.to = wsAnnotation.to.map { NormalizedPoint(x: $0.x, y: $0.y) }
    }
}

/// Represents an annotation anchored in 3D AR world space.
struct ARAnchoredAnnotation: Identifiable {
    let id: UUID
    let annotation: Annotation
    let worldPosition: simd_float3
    let createdAt: Date

    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > 10.0 // Auto-dismiss after 10 seconds
    }
}
