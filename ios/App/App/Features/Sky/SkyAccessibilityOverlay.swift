import SwiftUI
import UIKit

struct SkyAccessibilityOverlay: UIViewRepresentable {
    @ObservedObject var controller: SkySceneController

    func makeUIView(context: Context) -> SkyAccessibilityView {
        let view = SkyAccessibilityView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: SkyAccessibilityView, context: Context) {
        view.update(controller: controller)
    }
}

@MainActor
final class SkyAccessibilityView: UIView {
    private final class Element: UIAccessibilityElement {
        var action: (() -> Bool)?
        override func accessibilityActivate() -> Bool { action?() ?? false }
    }

    private var orderedElements: [Element] = []
    private weak var controller: SkySceneController?
    private var catalogueSignature = 0
    private var selectedID: String?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard UIAccessibility.isVoiceOverRunning, !bounds.isEmpty, let controller else { return }
        rebuild(controller: controller)
    }

    func update(controller: SkySceneController) {
        self.controller = controller
        accessibilityElementsHidden = !UIAccessibility.isVoiceOverRunning
        guard UIAccessibility.isVoiceOverRunning else {
            orderedElements = []
            accessibilityElements = nil
            accessibilityCustomRotors = nil
            return
        }
        let signature = controller.catalogue.stars.count &* 31
            &+ controller.catalogue.planets.count &* 17
            &+ controller.catalogue.constellations.count
        guard signature != catalogueSignature
                || selectedID != controller.camera.selectedID else { return }
        catalogueSignature = signature
        selectedID = controller.camera.selectedID
        rebuild(controller: controller)
    }

    private func rebuild(controller: SkySceneController) {
        isAccessibilityElement = false
        let viewport = SkyViewport(size: bounds.size)
        var elements: [Element] = []
        let starsByID = Dictionary(uniqueKeysWithValues: controller.catalogue.stars.map { ($0.albumID, $0) })
        let starsByRegion = Dictionary(grouping: controller.catalogue.stars, by: \.regionID)
        let constellationsByRegion = Dictionary(grouping: controller.catalogue.constellations, by: \.regionID)
        for region in controller.catalogue.regions {
            let element = Element(accessibilityContainer: self)
            element.accessibilityLabel = region.name
            element.accessibilityHint = "Region, \(region.starCount) albums"
            element.accessibilityTraits = .header
            elements.append(element)
            let constellations = constellationsByRegion[region.id] ?? []
            for constellation in constellations {
                let constellationElement = Element(accessibilityContainer: self)
                constellationElement.accessibilityLabel = constellation.artistName
                constellationElement.accessibilityHint = "Constellation, \(constellation.albumIDs.count) albums. Activate to locate."
                constellationElement.accessibilityTraits = .button
                constellationElement.action = { [weak controller] in
                    controller?.locate(id: constellation.id, reduceMotion: UIAccessibility.isReduceMotionEnabled)
                    return true
                }
                elements.append(constellationElement)
                for albumID in constellation.albumIDs {
                    guard let star = starsByID[albumID] else { continue }
                    elements.append(starElement(star, region: region.name, controller: controller, viewport: viewport))
                }
            }
            let figuredIDs = Set(constellations.flatMap(\.albumIDs))
            for star in starsByRegion[region.id] ?? [] where !figuredIDs.contains(star.albumID) {
                elements.append(starElement(star, region: region.name, controller: controller, viewport: viewport))
            }
        }
        for planet in controller.catalogue.planets {
            let element = Element(accessibilityContainer: self)
            element.accessibilityLabel = "World \(planet.index)"
            element.accessibilityHint = "Planet formed from albums \((planet.index - 1) * 20 + 1) through \(planet.index * 20). Activate to select."
            element.accessibilityTraits = controller.camera.selectedID == planet.id ? [.button, .selected] : .button
            let point = controller.camera.screenPoint(for: planet.coordinate, viewport: viewport)
            element.accessibilityFrameInContainerSpace = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            element.action = { [weak controller] in controller?.select(.planet(planet.id)); return true }
            elements.append(element)
        }
        orderedElements = elements
        accessibilityElements = elements
        accessibilityCustomRotors = [UIAccessibilityCustomRotor(name: "Aeon sky") { [weak self] predicate in
            guard let self, !self.orderedElements.isEmpty else { return nil }
            let current = predicate.currentItem.targetElement as? Element
            let currentIndex = current.flatMap { self.orderedElements.firstIndex(of: $0) }
                ?? (predicate.searchDirection == .next ? -1 : self.orderedElements.count)
            let next = predicate.searchDirection == .next ? currentIndex + 1 : currentIndex - 1
            guard self.orderedElements.indices.contains(next) else { return nil }
            return UIAccessibilityCustomRotorItemResult(targetElement: self.orderedElements[next], targetRange: nil)
        }]
    }

    private func starElement(
        _ star: SkyStar,
        region: String,
        controller: SkySceneController,
        viewport: SkyViewport
    ) -> Element {
        let element = Element(accessibilityContainer: self)
        element.accessibilityLabel = "\(star.albumID), \(star.artistName)"
        element.accessibilityHint = "Album in \(region). Activate to select."
        element.accessibilityTraits = controller.camera.selectedID == star.albumID ? [.button, .selected] : .button
        let point = controller.camera.screenPoint(for: star.coordinate, viewport: viewport)
        element.accessibilityFrameInContainerSpace = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
        element.action = { [weak controller] in controller?.select(.star(star.albumID)); return true }
        return element
    }
}
