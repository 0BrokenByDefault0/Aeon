import CoreGraphics
import Foundation

enum SkyZoomTier: String, Codable, CaseIterable, Sendable {
    case collection
    case system
    case album
    case focus
}

struct SkyViewport: Equatable, Sendable {
    let size: CGSize

    var center: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
}

struct SkyCameraState: Codable, Equatable, Sendable {
    static let minimumScale = 0.16
    static let maximumScale = 14.0
    static let home = SkyCameraState(centerX: 0, centerY: 0, scale: 0.72, selectedID: nil)

    var centerX: Double
    var centerY: Double
    var scale: Double
    var selectedID: String?

    var sanitized: SkyCameraState {
        guard centerX.isFinite, centerY.isFinite, scale.isFinite else { return .home }
        var value = self
        value.scale = min(Self.maximumScale, max(Self.minimumScale, scale))
        return value
    }

    var tier: SkyZoomTier {
        switch scale {
        case ..<0.65: return .collection
        case ..<1.6: return .system
        case ..<3.0: return .album
        default: return .focus
        }
    }

    func screenPoint(for point: SkyPoint, viewport: SkyViewport) -> CGPoint {
        CGPoint(
            x: viewport.center.x + (Double(point.x) - centerX) * scale,
            y: viewport.center.y + (Double(point.y) - centerY) * scale
        )
    }

    func worldPoint(for point: CGPoint, viewport: SkyViewport) -> CGPoint {
        CGPoint(
            x: centerX + Double(point.x - viewport.center.x) / scale,
            y: centerY + Double(point.y - viewport.center.y) / scale
        )
    }

    func panned(screenTranslation: CGSize) -> SkyCameraState {
        var result = self
        result.centerX -= Double(screenTranslation.width) / scale
        result.centerY -= Double(screenTranslation.height) / scale
        return result
    }

    func zoomed(by factor: Double, anchor: CGPoint, viewport: SkyViewport) -> SkyCameraState {
        let worldAnchor = worldPoint(for: anchor, viewport: viewport)
        let nextScale = min(Self.maximumScale, max(Self.minimumScale, scale * factor))
        var result = self
        result.scale = nextScale
        result.centerX = Double(worldAnchor.x) - Double(anchor.x - viewport.center.x) / nextScale
        result.centerY = Double(worldAnchor.y) - Double(anchor.y - viewport.center.y) / nextScale
        return result
    }

    func zoomedOutOneTier(anchor: CGPoint, viewport: SkyViewport) -> SkyCameraState {
        let target: Double
        switch tier {
        case .collection: target = Self.minimumScale
        case .system: target = 0.52
        case .album: target = 1.35
        case .focus: target = 2.4
        }
        return zoomed(by: target / scale, anchor: anchor, viewport: viewport)
    }

    func reframed(from oldViewport: SkyViewport, to newViewport: SkyViewport) -> SkyCameraState {
        self
    }

    func constrained(to points: [SkyPoint], viewport: SkyViewport, padding: Double = 180) -> SkyCameraState {
        guard let first = points.first else { return sanitized }
        var minX = Double(first.x), maxX = Double(first.x)
        var minY = Double(first.y), maxY = Double(first.y)
        for point in points.dropFirst() {
            minX = min(minX, Double(point.x)); maxX = max(maxX, Double(point.x))
            minY = min(minY, Double(point.y)); maxY = max(maxY, Double(point.y))
        }
        minX -= padding; maxX += padding; minY -= padding; maxY += padding
        let halfWidth = Double(viewport.size.width) / (2 * scale)
        let halfHeight = Double(viewport.size.height) / (2 * scale)
        var value = sanitized
        value.centerX = minX + halfWidth > maxX - halfWidth
            ? (minX + maxX) / 2 : min(maxX - halfWidth, max(minX + halfWidth, value.centerX))
        value.centerY = minY + halfHeight > maxY - halfHeight
            ? (minY + maxY) / 2 : min(maxY - halfHeight, max(minY + halfHeight, value.centerY))
        return value
    }

    static func framing(points: [SkyPoint], viewport: SkyViewport, padding: CGFloat = 56) -> SkyCameraState {
        guard let first = points.first else { return .home }
        var minX = Double(first.x)
        var maxX = minX
        var minY = Double(first.y)
        var maxY = minY
        for point in points.dropFirst() {
            minX = min(minX, Double(point.x))
            maxX = max(maxX, Double(point.x))
            minY = min(minY, Double(point.y))
            maxY = max(maxY, Double(point.y))
        }
        let availableWidth = max(1, viewport.size.width - padding * 2)
        let availableHeight = max(1, viewport.size.height - padding * 2)
        let widthScale = Double(availableWidth) / max(1, maxX - minX)
        let heightScale = Double(availableHeight) / max(1, maxY - minY)
        return SkyCameraState(
            centerX: (minX + maxX) / 2,
            centerY: (minY + maxY) / 2,
            scale: min(Self.maximumScale, max(Self.minimumScale, min(widthScale, heightScale))),
            selectedID: nil
        )
    }

    /// Frames a local celestial figure as the primary object instead of merely moving
    /// it to the middle of the display. The longest projected edge lands at roughly
    /// 35% of the shorter viewport dimension, inside the product's 25-45% focus range.
    static func focusFraming(
        points: [SkyPoint],
        viewport: SkyViewport,
        targetFraction: Double = 0.35
    ) -> SkyCameraState {
        guard let first = points.first else { return .home }
        var minX = Double(first.x), maxX = minX
        var minY = Double(first.y), maxY = minY
        for point in points.dropFirst() {
            minX = min(minX, Double(point.x)); maxX = max(maxX, Double(point.x))
            minY = min(minY, Double(point.y)); maxY = max(maxY, Double(point.y))
        }
        let longestEdge = max(1, max(maxX - minX, maxY - minY))
        let usableShortEdge = Double(max(1, min(viewport.size.width, viewport.size.height) - 72))
        let scale = usableShortEdge * min(0.45, max(0.25, targetFraction)) / longestEdge
        return SkyCameraState(
            centerX: (minX + maxX) / 2,
            centerY: (minY + maxY) / 2,
            scale: min(Self.maximumScale, max(3.05, scale)),
            selectedID: nil
        )
    }
}

enum SkyCameraTransitionKind: Equatable, Sendable {
    case flight
    case crossFade
}

struct SkyCameraTransition: Equatable, Sendable {
    let target: SkyCameraState
    let kind: SkyCameraTransitionKind

    static func locate(
        _ point: SkyPoint,
        from camera: SkyCameraState,
        reduceMotion: Bool
    ) -> SkyCameraTransition {
        SkyCameraTransition(
            target: SkyCameraState(
                centerX: Double(point.x),
                centerY: Double(point.y),
                scale: max(camera.scale, 3.2),
                selectedID: camera.selectedID
            ),
            kind: reduceMotion ? .crossFade : .flight
        )
    }
}
