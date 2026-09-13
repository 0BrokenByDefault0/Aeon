import Combine
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

@MainActor
final class SkySceneController: ObservableObject {
    @Published private(set) var catalogue: SkyCatalogue
    @Published private(set) var camera: SkyCameraState
    @Published private(set) var ceremony: String?
    @Published private(set) var nowPlayingText: String?
    @Published private(set) var playingStarID: String?
    @Published private(set) var captureURL: URL?
    @Published private(set) var cameraCrossfade = false
    @Published private(set) var spectrumLevels = SpectrumLevels.zero

    private let repository: SkyRepository
    private let catalog: CatalogRepository
    private var playbackObservation: AnyCancellable?
    private var spectrumObservation: AnyCancellable?
    private var ceremonyTask: Task<Void, Never>?
    private var cameraTask: Task<Void, Never>?

    init(
        repository: SkyRepository,
        catalog: CatalogRepository,
        playback: PlaybackController,
        spectrum: SpectrumAnalyzer? = nil
    ) {
        self.repository = repository
        self.catalog = catalog
        if let fixture = Self.fixtureName(), let generated = try? Self.fixture(named: fixture) {
            catalogue = generated
            camera = SkyCameraState.framing(
                points: generated.stars.map(\.coordinate) + generated.planets.map(\.coordinate),
                viewport: SkyViewport(size: CGSize(width: 390, height: 844))
            )
        } else {
            catalogue = (try? repository.catalogue()) ?? .empty
            camera = (try? repository.camera()) ?? .home
        }
        if Self.fixtureName() == "planet-selected", let planet = catalogue.planets.first {
            camera.selectedID = planet.id
        } else if Self.fixtureName() == "playing", let star = catalogue.stars.first {
            playingStarID = star.albumID
            nowPlayingText = "now burning · Signal 1 · Artist 0"
        }
        playbackObservation = playback.$snapshot.sink { [weak self] snapshot in
            self?.acceptPlayback(trackID: snapshot?.trackID)
        }
        spectrumObservation = spectrum?.$bands.sink { [weak self, weak spectrum] bands in
            self?.spectrumLevels = spectrum?.levels(from: bands) ?? .zero
        }
        if Self.fixtureName() == "playing", let star = catalogue.stars.first {
            playingStarID = star.albumID
            nowPlayingText = "now burning · Signal 1 · Artist 0"
        }
    }

    deinit {
        ceremonyTask?.cancel()
        cameraTask?.cancel()
    }

    var selectedStar: SkyStar? {
        guard let selectedID = camera.selectedID else { return nil }
        return catalogue.stars.first { $0.albumID == selectedID }
    }

    var selectedPlanet: SkyPlanet? {
        guard let selectedID = camera.selectedID else { return nil }
        return catalogue.planets.first { $0.id == selectedID }
    }

    var censusText: String {
        "\(catalogue.stars.count) albums adrift · \(catalogue.constellations.count) constellations"
    }

    var planetProgressText: String {
        let remainder = catalogue.stars.count % SkyComposer.albumsPerPlanet
        let remaining = remainder == 0 && !catalogue.stars.isEmpty ? SkyComposer.albumsPerPlanet : SkyComposer.albumsPerPlanet - remainder
        return "\(remaining) until the next world"
    }

    func setCamera(_ value: SkyCameraState, persist: Bool = false) {
        cameraTask?.cancel()
        cameraCrossfade = false
        camera = value.sanitized
        if persist, Self.fixtureName() == nil { try? repository.save(camera: camera) }
    }

    func select(_ target: SkyHitTarget?) {
        var updated = camera
        updated.selectedID = target?.id
        setCamera(updated, persist: true)
    }

    func locate(id: String, reduceMotion: Bool) {
        let point: SkyPoint?
        if let star = catalogue.stars.first(where: { $0.albumID == id }) { point = star.coordinate }
        else if let planet = catalogue.planets.first(where: { $0.id == id }) { point = planet.coordinate }
        else if let constellation = catalogue.constellations.first(where: { $0.id == id }) {
            let memberPoints = catalogue.stars.filter { constellation.albumIDs.contains($0.albumID) }.map(\.coordinate)
            guard !memberPoints.isEmpty else { return }
            point = SkyPoint(
                x: Int32(memberPoints.map { Int64($0.x) }.reduce(0, +) / Int64(memberPoints.count)),
                y: Int32(memberPoints.map { Int64($0.y) }.reduce(0, +) / Int64(memberPoints.count))
            )
        } else { point = nil }
        guard let point else { return }
        var transition = SkyCameraTransition.locate(point, from: camera, reduceMotion: reduceMotion)
        transition = SkyCameraTransition(
            target: SkyCameraState(
                centerX: transition.target.centerX,
                centerY: transition.target.centerY,
                scale: transition.target.scale,
                selectedID: id
            ),
            kind: transition.kind
        )
        cameraTask?.cancel()
        let origin = camera
        if transition.kind == .crossFade {
            cameraTask = Task { [weak self] in
                self?.cameraCrossfade = true
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, let self else { return }
                self.camera = transition.target.sanitized
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                self.cameraCrossfade = false
                if Self.fixtureName() == nil { try? self.repository.save(camera: self.camera) }
            }
        } else {
            cameraTask = Task { [weak self] in
                let steps = 24
                for step in 1...steps {
                    guard !Task.isCancelled, let self else { return }
                    let linear = Double(step) / Double(steps)
                    let eased = linear * linear * (3 - 2 * linear)
                    self.camera = SkyCameraState(
                        centerX: origin.centerX + (transition.target.centerX - origin.centerX) * eased,
                        centerY: origin.centerY + (transition.target.centerY - origin.centerY) * eased,
                        scale: origin.scale + (transition.target.scale - origin.scale) * eased,
                        selectedID: transition.target.selectedID
                    )
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                guard !Task.isCancelled, let self else { return }
                if Self.fixtureName() == nil { try? self.repository.save(camera: self.camera) }
            }
        }
    }

    func locatePlaying(reduceMotion: Bool) {
        guard let playingStarID else { return }
        locate(id: playingStarID, reduceMotion: reduceMotion)
    }

    func reload() {
        guard let updated = try? repository.catalogue() else { return }
        let newConstellations = updated.constellations.count - catalogue.constellations.count
        let newPlanets = updated.planets.count - catalogue.planets.count
        catalogue = updated
        if newPlanets > 0 { announce("A new world wakes") }
        else if newConstellations > 0 { announce("A constellation forms") }
    }

    func makeCapture(wide: Bool, viewport: CGSize) {
        let outputSize = CGSize(width: 1_170, height: 2_532)
        let framingScale = min(outputSize.width / max(1, viewport.width), outputSize.height / max(1, viewport.height))
        var plateCamera = camera
        plateCamera.scale *= Double(framingScale) * (wide ? 0.62 : 1)
        let plateViewport = SkyViewport(size: outputSize)
        let renderer = UIGraphicsImageRenderer(size: outputSize)
        let image = renderer.image { context in
            UIColor(red: 0.003, green: 0.004, blue: 0.007, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))
            let graphics = context.cgContext
            graphics.setLineWidth(1)
            graphics.setStrokeColor(UIColor(white: 0.7, alpha: 0.28).cgColor)
            let starByID = Dictionary(uniqueKeysWithValues: catalogue.stars.map { ($0.albumID, $0) })
            for constellation in catalogue.constellations {
                for segment in constellation.figureSegments {
                    guard let from = starByID[segment.fromAlbumID], let to = starByID[segment.toAlbumID] else { continue }
                    graphics.move(to: plateCamera.screenPoint(for: from.coordinate, viewport: plateViewport))
                    graphics.addLine(to: plateCamera.screenPoint(for: to.coordinate, viewport: plateViewport))
                    graphics.strokePath()
                }
            }
            for star in catalogue.stars {
                let point = plateCamera.screenPoint(for: star.coordinate, viewport: plateViewport)
                let radius = CGFloat(2 + Int(star.magnitude) / 48)
                graphics.setFillColor(UIColor(white: star.isUncharted ? 0.74 : 0.94, alpha: 1).cgColor)
                graphics.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            }
            for planet in catalogue.planets {
                let point = plateCamera.screenPoint(for: planet.coordinate, viewport: plateViewport)
                let color = planet.descriptor.bandColors.first ?? SkyColor(red: 120, green: 132, blue: 150)
                graphics.setFillColor(UIColor(
                    red: CGFloat(color.red) / 255,
                    green: CGFloat(color.green) / 255,
                    blue: CGFloat(color.blue) / 255,
                    alpha: 1
                ).cgColor)
                graphics.fillEllipse(in: CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36))
            }
            let title = selectedTitle() ?? "AEON / SKY"
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .medium),
                .foregroundColor: UIColor(white: 0.92, alpha: 1),
                .kern: 3
            ]
            title.uppercased().draw(at: CGPoint(x: 64, y: 72), withAttributes: titleAttributes)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy.MM.dd"
            let credit = "AEON · \(formatter.string(from: Date())) · \(catalogue.stars.count) STARS"
            credit.draw(
                at: CGPoint(x: 64, y: outputSize.height - 96),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 18, weight: .regular),
                    .foregroundColor: UIColor(white: 0.68, alpha: 1),
                    .kern: 2
                ]
            )
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("aeon-sky-\(UUID().uuidString).png")
        guard let data = image.pngData(), (try? data.write(to: url, options: .atomic)) != nil else { return }
        if let captureURL { try? FileManager.default.removeItem(at: captureURL) }
        captureURL = url
    }

    func hitCandidates() -> [SkyHitCandidate] {
        let stars = catalogue.stars.map {
            SkyHitCandidate(target: .star($0.albumID), coordinate: $0.coordinate, visualRadius: 6)
        }
        let planets = catalogue.planets.map {
            SkyHitCandidate(target: .planet($0.id), coordinate: $0.coordinate, visualRadius: 24)
        }
        let starMap = Dictionary(uniqueKeysWithValues: catalogue.stars.map { ($0.albumID, $0.coordinate) })
        let constellations = catalogue.constellations.compactMap { constellation -> SkyHitCandidate? in
            let points = constellation.albumIDs.compactMap { starMap[$0] }
            guard !points.isEmpty else { return nil }
            return SkyHitCandidate(
                target: .constellation(constellation.id),
                coordinate: SkyPoint(
                    x: Int32(points.map { Int64($0.x) }.reduce(0, +) / Int64(points.count)),
                    y: Int32(points.map { Int64($0.y) }.reduce(0, +) / Int64(points.count))
                ),
                visualRadius: 28
            )
        }
        return stars + planets + constellations
    }

    private func acceptPlayback(trackID: String?) {
        guard let trackID,
              let track = try? catalog.track(id: trackID),
              let album = try? catalog.album(id: track.albumID) else {
            nowPlayingText = nil
            playingStarID = nil
            return
        }
        playingStarID = album.id
        nowPlayingText = "now burning · \(track.title) · \(album.artist)"
    }

    private func announce(_ message: String) {
        ceremonyTask?.cancel()
        ceremony = message
        ceremonyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.ceremony = nil
        }
    }

    private func selectedTitle() -> String? {
        if let selectedPlanet { return "WORLD \(selectedPlanet.index)" }
        if let selectedStar { return "\(selectedStar.artistName) / \(selectedStar.albumID)" }
        return nil
    }

    private static func fixtureName() -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-AeonSkyFixture"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    private static func fixture(named name: String) throws -> SkyCatalogue {
        let count: Int
        switch name {
        case "small", "playing", "planet-selected", "uncharted": count = 48
        case "1000": count = 1_000
        case "10000": count = 10_000
        default: count = 0
        }
        let genres = ["Ambient", "Electronic", "Jazz", "Soul"]
        var albums: [SkyAlbumInput] = []
        albums.reserveCapacity(count)
        for index in 0..<count {
            let artist = name == "uncharted" ? "Unknown \(index)" : "Artist \(index % 24)"
            let genre = name == "uncharted" ? "" : genres[index % genres.count]
            albums.append(SkyAlbumInput(
                id: "fixture-album-\(index)",
                sequence: Int64(index + 1),
                title: "Signal \(index + 1)",
                artist: artist,
                genre: genre,
                importedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)),
                magnitude: UInt8(48 + index % 160)
            ))
        }
        return try SkyComposer().compose(albums: albums)
    }
}
