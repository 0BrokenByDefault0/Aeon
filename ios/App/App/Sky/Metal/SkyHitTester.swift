import CoreGraphics
import Foundation

enum SkyHitTarget: Equatable, Sendable {
    case star(String)
    case planet(String)
    case constellation(String)

    var id: String {
        switch self {
        case .star(let id), .planet(let id), .constellation(let id): return id
        }
    }
}

struct SkyHitCandidate: Equatable, Sendable {
    let target: SkyHitTarget
    let coordinate: SkyPoint
    let visualRadius: CGFloat

    var priority: Int {
        switch target {
        case .star: return 0
        case .planet: return 1
        case .constellation: return 2
        }
    }
}

struct SkyHitTester {
    static let minimumTouchDiameter: CGFloat = 44

    func hit(
        screenPoint: CGPoint,
        candidates: [SkyHitCandidate],
        camera: SkyCameraState,
        viewport: SkyViewport
    ) -> SkyHitTarget? {
        candidates.compactMap { candidate -> (SkyHitCandidate, CGFloat)? in
            let position = camera.screenPoint(for: candidate.coordinate, viewport: viewport)
            let distance = hypot(screenPoint.x - position.x, screenPoint.y - position.y)
            let radius = max(Self.minimumTouchDiameter / 2, candidate.visualRadius)
            return distance <= radius ? (candidate, distance) : nil
        }.sorted {
            // A nearby real album wins over an aggregate artist target.
            if $0.0.priority != 2 && $1.0.priority == 2 { return true }
            if $0.0.priority == 2 && $1.0.priority != 2 { return false }
            if abs($0.1 - $1.1) > 0.0001 { return $0.1 < $1.1 }
            return $0.0.priority < $1.0.priority
        }.first?.0.target
    }
}
