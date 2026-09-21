import MetalKit
import SwiftUI

struct SkyMetalView: UIViewRepresentable {
    @ObservedObject var controller: SkySceneController
    let reduceMotionOverride: Bool
    let commitSelection: (String) -> Void
    var isForeground = true
    var usableSize = CGSize.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, commitSelection: commitSelection) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        view.isOpaque = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Interactive collection sky"
        view.accessibilityTraits = .image
        view.accessibilityIdentifier = "aeon.sky.canvas"
        context.coordinator.install(on: view)
        if AeonTestOverrides.staticSky {
            view.enableSetNeedsDisplay = true
            view.isPaused = true
            view.setNeedsDisplay()
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        let effectiveReduceMotion = reduceMotion || reduceMotionOverride || AeonTestOverrides.reduceMotion
        context.coordinator.controller = controller
        context.coordinator.commitSelection = commitSelection
        context.coordinator.reduceMotion = effectiveReduceMotion
        controller.updateViewport(view.bounds.size)
        view.accessibilityValue = "\(controller.catalogue.stars.count) albums, \(controller.catalogue.constellations.count) artist constellations, \(controller.catalogue.planets.count) worlds"
        context.coordinator.renderer?.update(
            catalogue: controller.catalogue,
            camera: controller.camera,
            playingStarID: controller.playingStarID,
            spectrum: effectiveReduceMotion ? .zero : controller.spectrumLevels,
            animateSelection: !effectiveReduceMotion,
            usableSize: usableSize == .zero ? controller.usableSkySize : usableSize
        )
        context.coordinator.renderer?.configureFrameRate(for: view)
        // The sky stays mounted behind utility panels so the camera survives, but an
        // opaque panel covers every pixel of it. Driving the draw loop at 60fps into a
        // surface nobody can see is pure battery cost, so decorative motion stops with
        // effectiveReduceMotion || !isForeground and only resumes on return.
        if !AeonTestOverrides.staticSky {
            view.isPaused = !isForeground
            view.enableSetNeedsDisplay = !isForeground
        }
        if AeonTestOverrides.staticSky { view.setNeedsDisplay() }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var controller: SkySceneController
        var commitSelection: (String) -> Void
        var renderer: SkyRenderer?
        var reduceMotion = false
        private var lastPanTranslation = CGPoint.zero
        private var lastPinchScale: CGFloat = 1
        private let hitTester = SkyHitTester()

        init(controller: SkySceneController, commitSelection: @escaping (String) -> Void) {
            self.controller = controller; self.commitSelection = commitSelection
        }

        func install(on view: MTKView) {
            renderer = SkyRenderer(view: view)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(hold(_:)))
            hold.minimumPressDuration = 0.6
            pan.delegate = self
            pinch.delegate = self
            singleTap.require(toFail: hold)
            singleTap.require(toFail: doubleTap)
            [pan, pinch, singleTap, doubleTap, hold].forEach(view.addGestureRecognizer)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            controller.interruptFlight()
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            (gestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer is UIPinchGestureRecognizer)
                || (gestureRecognizer is UIPinchGestureRecognizer && otherGestureRecognizer is UIPanGestureRecognizer)
        }

        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            if gesture.state == .began {
                lastPanTranslation = .zero
                // A direct touch always wins over a pending locate/coast transition.
                controller.setCamera(controller.camera)
            }
            let translation = gesture.translation(in: view)
            let delta = CGPoint(x: translation.x - lastPanTranslation.x, y: translation.y - lastPanTranslation.y)
            lastPanTranslation = translation
            let camera = controller.camera.panned(screenTranslation: delta.asSize)
            switch gesture.state {
            case .began, .changed:
                controller.setCamera(camera)
            case .ended:
                // Persist the exact finger-up camera. SwiftUI animation cannot interpolate an
                // ObservableObject camera mutation, and the old velocity jump made the sky skip.
                controller.setCamera(camera, persist: true)
            case .cancelled, .failed:
                controller.setCamera(camera, persist: true)
            default: break
            }
        }

        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view = gesture.view else { return }
            let viewport = SkyViewport(size: view.bounds.size)
            if gesture.state == .began {
                lastPinchScale = gesture.scale
                controller.setCamera(controller.camera)
            }
            // Apply only the incremental scale since the last callback. This composes correctly
            // with simultaneous pan instead of repeatedly restoring a stale pinch-start camera.
            let incremental = gesture.scale / max(0.0001, lastPinchScale)
            lastPinchScale = gesture.scale
            controller.zoom(
                by: Double(incremental),
                anchor: gesture.location(in: view),
                viewport: viewport,
                persist: gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed
            )
        }

        @objc private func tap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let point = gesture.location(in: view)
            let viewport = SkyViewport(size: view.bounds.size)
            let target = hitTester.hit(
                screenPoint: point,
                candidates: controller.hitCandidates(),
                camera: controller.camera,
                viewport: viewport
            )
            if case .star(let id) = target, controller.selectedStar?.albumID == id {
                commitSelection(id)
            } else if case .star(let id) = target {
                controller.locate(id: id, reduceMotion: reduceMotion)
            } else if case .constellation(let id) = target {
                controller.locate(id: id, reduceMotion: reduceMotion)
            } else if case .planet(let id) = target {
                controller.locate(id: id, reduceMotion: reduceMotion)
            } else {
                controller.select(target)
            }
        }

        @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let point = gesture.location(in: view)
            let viewport = SkyViewport(size: view.bounds.size)
            let occupied = hitTester.hit(
                screenPoint: point,
                candidates: controller.hitCandidates(),
                camera: controller.camera,
                viewport: viewport
            ) != nil
            guard !occupied else { return }
            let camera = controller.camera.zoomedOutOneTier(anchor: point, viewport: viewport)
            if reduceMotion { controller.setCamera(camera, persist: true) }
            else { withAnimation(.easeOut(duration: 0.36)) { controller.setCamera(camera, persist: true) } }
        }

        @objc private func hold(_ gesture: UILongPressGestureRecognizer) {}
    }
}

private extension CGPoint {
    var asSize: CGSize { CGSize(width: x, height: y) }
}
