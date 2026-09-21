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
    static let minimumScale = 0.015
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
        // Allow exploration past the content edge. Clamping the entire viewport inside
        // the bounds used to recenter small collections during a perfectly valid pinch.
        let margin = max(padding, Double(max(viewport.size.width, viewport.size.height)) / scale)
        minX -= margin; maxX += margin; minY -= margin; maxY += margin
        var value = sanitized
        value.centerX = min(maxX, max(minX, value.centerX))
        value.centerY = min(maxY, max(minY, value.centerY))
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
            scale: min(0.72, max(Self.minimumScale, min(widthScale, heightScale))),
            selectedID: nil
        )
    }

    /// Only real artist members are framed as geometry. An album has no extent;
    /// its single star's screen-space core and halo resolve in the shader.
    static func albumFocus(_ point: SkyPoint, id: String) -> SkyCameraState {
        SkyCameraState(centerX: Double(point.x), centerY: Double(point.y), scale: 5, selectedID: id)
    }

    static func planetFocus(_ planet: SkyPlanet, viewport: SkyViewport) -> SkyCameraState {
        SkyCameraState(centerX: Double(planet.coordinate.x), centerY: Double(planet.coordinate.y),
                       scale: Double(min(viewport.size.width, viewport.size.height)) * 0.55 / 56,
                       selectedID: planet.id).sanitized
    }

    static func focusFraming(
        points: [SkyPoint],
        viewport: SkyViewport,
        targetFraction: Double = 0.45
    ) -> SkyCameraState {
        guard let first = points.first else { return .home }
        var minX = Double(first.x), maxX = minX
        var minY = Double(first.y), maxY = minY
        for point in points.dropFirst() {
            minX = min(minX, Double(point.x)); maxX = max(maxX, Double(point.x))
            minY = min(minY, Double(point.y)); maxY = max(maxY, Double(point.y))
        }
        let longestEdge = max(1, max(maxX - minX, maxY - minY))
        let usableShortEdge = Double(max(1, min(viewport.size.width, viewport.size.height)))
        let scale = usableShortEdge * min(0.55, max(0.35, targetFraction)) / longestEdge
        return SkyCameraState(
            centerX: (minX + maxX) / 2,
            centerY: (minY + maxY) / 2,
            scale: min(Self.maximumScale, max(Self.minimumScale, scale)),
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
