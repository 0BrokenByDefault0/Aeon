import MetalKit
import SwiftUI

struct SkyMetalView: UIViewRepresentable {
    @ObservedObject var controller: SkySceneController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black
        view.isOpaque = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Interactive collection sky"
        view.accessibilityTraits = .image
        view.accessibilityIdentifier = "aeon.sky.canvas"
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.reduceMotion = reduceMotion
        context.coordinator.renderer?.update(
            catalogue: controller.catalogue,
            camera: controller.camera,
            playingStarID: controller.playingStarID
        )
        context.coordinator.renderer?.configureFrameRate(for: view)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var controller: SkySceneController
        var renderer: SkyRenderer?
        var reduceMotion = false
        private var panStart = SkyCameraState.home
        private var pinchStart = SkyCameraState.home
        private let hitTester = SkyHitTester()

        init(controller: SkySceneController) { self.controller = controller }

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
            singleTap.require(toFail: doubleTap)
            singleTap.require(toFail: hold)
            [pan, pinch, singleTap, doubleTap, hold].forEach(view.addGestureRecognizer)
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
            if gesture.state == .began { panStart = controller.camera }
            let camera = panStart.panned(screenTranslation: gesture.translation(in: view).asSize)
            switch gesture.state {
            case .began, .changed:
                controller.setCamera(camera)
            case .ended:
                let velocity = gesture.velocity(in: view)
                let coast = camera.panned(screenTranslation: CGSize(width: velocity.x * 0.11, height: velocity.y * 0.11))
                if reduceMotion { controller.setCamera(camera, persist: true) }
                else { withAnimation(.easeOut(duration: 0.42)) { controller.setCamera(coast, persist: true) } }
            case .cancelled, .failed:
                controller.setCamera(camera, persist: true)
            default: break
            }
        }

        @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
            guard let view = gesture.view else { return }
            if gesture.state == .began { pinchStart = controller.camera }
            let viewport = SkyViewport(size: view.bounds.size)
            let camera = pinchStart.zoomed(
                by: Double(gesture.scale),
                anchor: gesture.location(in: view),
                viewport: viewport
            )
            controller.setCamera(camera, persist: gesture.state == .ended || gesture.state == .cancelled)
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
            if case .constellation(let id) = target {
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
