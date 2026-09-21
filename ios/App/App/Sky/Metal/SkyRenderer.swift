import MetalKit
import OSLog
import QuartzCore
import simd

struct SkyRendererStats: Equatable {
    var catalogueUploads = 0
    var selectionUploads = 0
    var renderedFrames: UInt64 = 0
}

@MainActor
final class SkyRenderer: NSObject, MTKViewDelegate {
    private struct GPUInstance {
        var position: SIMD2<Float>
        var positionPadding = SIMD2<Float>(repeating: 0)
        var color0: SIMD4<Float>
        var color1: SIMD4<Float>
        var color2: SIMD4<Float>
        var size: Float
        var flags: UInt32
        var turbulence: Float
        var tailPadding: UInt32 = 0
    }

    private struct GPULine {
        var position: SIMD2<Float>
        var positionPadding = SIMD2<Float>(repeating: 0)
        var color: SIMD4<Float>
    }

    private struct Uniforms {
        var center: SIMD2<Float>
        var viewport: SIMD2<Float>
        var scale: Float
        var time: Float
        var spectrum = SIMD4<Float>(repeating: 0)
    }

    private static let performanceLog = OSLog(subsystem: "app.isolation.sky", category: "SkyRenderer")

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let starPipeline: MTLRenderPipelineState
    private let glowPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let planetPipeline: MTLRenderPipelineState

    private var stars: [SkyStar] = []
    private var planets: [SkyPlanet] = []
    private var constellations: [SkyConstellation] = []
    private var selectedID: String?
    private var playingStarID: String?
    private var animateSelection = true
    private var spectrum = SpectrumLevels.zero
    private var camera = SkyCameraState.home
    private var backdropBuffer: MTLBuffer?
    private var starBuffer: MTLBuffer?
    private var glowBuffer: MTLBuffer?
    private let backdrop: [GPUInstance] = SkyRenderer.makeBackdrop()
    private var lineBuffer: MTLBuffer?
    private var planetBuffer: MTLBuffer?
    private var starCount = 0
    private var glowCount = 0
    private var lineCount = 0
    private var planetCount = 0
    private(set) var stats = SkyRendererStats()

    init?(view: MTKView) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "skyInstanceVertex"),
              let lineVertex = library.makeFunction(name: "skyLineVertex"),
              let starFragment = library.makeFunction(name: "skyStarFragment"),
              let glowFragment = library.makeFunction(name: "skyGlowFragment"),
              let lineFragment = library.makeFunction(name: "skyLineFragment"),
              let planetFragment = library.makeFunction(name: "skyPlanetFragment") else { return nil }
        self.device = device
        commandQueue = queue
        do {
            starPipeline = try Self.pipeline(device: device, view: view, vertex: vertex, fragment: starFragment, additive: true)
            glowPipeline = try Self.pipeline(device: device, view: view, vertex: vertex, fragment: glowFragment, additive: true)
            linePipeline = try Self.pipeline(device: device, view: view, vertex: lineVertex, fragment: lineFragment, additive: true)
            planetPipeline = try Self.pipeline(device: device, view: view, vertex: vertex, fragment: planetFragment, additive: false)
        } catch { return nil }
        super.init()
        view.device = device
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.003, green: 0.004, blue: 0.007, alpha: 1)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
    }

    func update(
        catalogue: SkyCatalogue,
        camera: SkyCameraState,
        playingStarID: String? = nil,
        spectrum: SpectrumLevels = .zero,
        animateSelection: Bool = true
    ) {
        let catalogueChanged = stars != catalogue.stars || planets != catalogue.planets || constellations != catalogue.constellations || starBuffer == nil
        let selectionChanged = selectedID != camera.selectedID || self.playingStarID != playingStarID || self.animateSelection != animateSelection
        let spectrumChanged = self.spectrum != spectrum
        self.camera = camera
        self.spectrum = spectrum
        guard catalogueChanged || selectionChanged || spectrumChanged else { return }
        if catalogueChanged {
            stars = catalogue.stars
            planets = catalogue.planets
            constellations = catalogue.constellations
            stats.catalogueUploads += 1
        }
        selectedID = camera.selectedID
        self.playingStarID = playingStarID
        self.animateSelection = animateSelection
        if catalogueChanged || selectionChanged {
            rebuildStaticLineBuffer()
            rebuildSelectionBuffers()
            stats.selectionUploads += 1
        }
    }

    func configureFrameRate(for view: MTKView) {
        view.preferredFramesPerSecond = stars.count >= 10_000 ? 30 : 60
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        os_signpost(.begin, log: Self.performanceLog, name: "SkyFrame")
        let screenScale = Float(view.contentScaleFactor)
        var uniforms = Uniforms(
            center: SIMD2(Float(camera.centerX), Float(camera.centerY)),
            viewport: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            scale: Float(camera.scale) * screenScale,
            time: animateSelection ? Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 10_000)) : 0,
            spectrum: SIMD4(spectrum.low, spectrum.mid, spectrum.high, screenScale)
        )
        encodeInstances(encoder, pipeline: starPipeline, buffer: backdropBuffer, count: backdrop.count, uniforms: &uniforms)
        encodeLines(encoder, buffer: lineBuffer, count: lineCount, uniforms: &uniforms)
        encodeInstances(encoder, pipeline: glowPipeline, buffer: glowBuffer, count: glowCount, uniforms: &uniforms)
        encodeInstances(encoder, pipeline: starPipeline, buffer: starBuffer, count: starCount, uniforms: &uniforms)
        encodeInstances(encoder, pipeline: planetPipeline, buffer: planetBuffer, count: planetCount, uniforms: &uniforms)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        stats.renderedFrames &+= 1
        os_signpost(.end, log: Self.performanceLog, name: "SkyFrame")
    }

    private func rebuildSelectionBuffers() {
        let artist = constellations.first { $0.id == selectedID }
        let members = Set(artist?.albumIDs ?? [])
        let albumInstances = stars.map { star in
            let selected = star.albumID == selectedID
            let related = members.contains(star.albumID)
            let playing = star.albumID == playingStarID
            let alpha: Float = selectedID == nil || selected || related ? 1 : (playing ? 0.82 : 0.40)
            let temperatures: [SIMD3<Float>] = [
                SIMD3(0.67, 0.80, 1), SIMD3(0.86, 0.92, 1), SIMD3(1, 0.91, 0.73)
            ]
            var rgb = temperatures[Int(SkyStableHash.value(star.albumID) % 3)]
            if let sample = star.spectralColor {
                // A spectral influence, not literal saturated artwork colour.
                let artwork = SIMD3(Float(sample.red), Float(sample.green), Float(sample.blue)) / 255
                rgb = rgb * 0.72 + artwork * 0.28
            }
            let color = SIMD4(rgb.x, rgb.y, rgb.z, alpha)
            return GPUInstance(
                position: SIMD2(Float(star.coordinate.x), Float(star.coordinate.y)),
                color0: color, color1: color, color2: color, size: related ? 3.4 : 2.7,
                flags: 0x8000 | (selected ? 0x4000 : 0) | (playing ? 0x200 : 0)
                    | (selected && animateSelection ? 0x1000 : 0), turbulence: 0
            )
        }
        // Exactly one luminous core per real album. Glows share that core's anchor.
        if backdropBuffer == nil { backdropBuffer = makeBuffer(backdrop) }
        starBuffer = makeBuffer(albumInstances)
        starCount = albumInstances.count
        let glows = albumInstances.map { instance -> GPUInstance in
            var glow = instance
            glow.flags |= 1
            glow.color0.w *= (instance.flags & 0x4000) != 0 ? 0.42 : ((instance.flags & 0x200) != 0 ? 0.30 : 0.20)
            return glow
        }
        glowBuffer = makeBuffer(glows)
        glowCount = glows.count
        let worlds = planets.map { planetInstance($0, selected: $0.id == selectedID) }
        planetBuffer = makeBuffer(worlds)
        planetCount = worlds.count
    }

    private func rebuildStaticLineBuffer() {
        let starByID = Dictionary(uniqueKeysWithValues: stars.map { ($0.albumID, $0) })
        var lines: [GPULine] = []
        for constellation in constellations {
            let selected = constellation.id == selectedID
            let alpha: Float = selected ? 0.48 : (selectedID == nil ? 0.18 : 0.035)
            for segment in constellation.figureSegments {
                guard let from = starByID[segment.fromAlbumID], let to = starByID[segment.toAlbumID] else { continue }
                let dx = Double(from.coordinate.x) - Double(to.coordinate.x)
                let dy = Double(from.coordinate.y) - Double(to.coordinate.y)
                guard dx * dx + dy * dy <= pow(Double(SkyComposer.starSpacing * 4), 2) else { continue }
                let color = SIMD4<Float>(0.64, 0.73, 0.85, alpha)
                // Length in the existing padding lets the shader attenuate edges before
                // they can become enormous rays. Selected artists can resolve at any scale.
                let detail = SIMD2<Float>(Float(hypot(dx, dy)), selected ? 1 : 0)
                lines.append(GPULine(position: SIMD2(Float(from.coordinate.x), Float(from.coordinate.y)),
                                     positionPadding: detail, color: color))
                lines.append(GPULine(position: SIMD2(Float(to.coordinate.x), Float(to.coordinate.y)),
                                     positionPadding: detail, color: color))
            }
        }
        lineCount = lines.count
        lineBuffer = makeBuffer(lines)
    }

    private func planetInstance(_ planet: SkyPlanet, selected: Bool) -> GPUInstance {
        let colors = planet.descriptor.bandColors
        func vector(_ index: Int) -> SIMD4<Float> {
            let color = colors.isEmpty ? SkyColor(red: 120, green: 132, blue: 150) : colors[index % colors.count]
            return SIMD4(Float(color.red) / 255, Float(color.green) / 255, Float(color.blue) / 255,
                         selectedID == nil || selected ? 1 : 0.38)
        }
        // The analytic sphere uses the persisted descriptor at every LOD. No bitmap
        // upscale, texture swap, or CPU texture generation in a camera transaction.
        return GPUInstance(
            position: SIMD2(Float(planet.coordinate.x), Float(planet.coordinate.y)),
            color0: vector(0), color1: vector(1), color2: vector(2), size: 28,
            flags: 2 | (planet.descriptor.hasRings ? 0x100 : 0),
            turbulence: Float(planet.seed % 10007) / 100
        )
    }

    private func makeBuffer<Element>(_ values: [Element]) -> MTLBuffer? {
        guard !values.isEmpty else { return nil }
        return values.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: address, length: bytes.count, options: .storageModeShared)
        }
    }

    private static func makeBackdrop() -> [GPUInstance] {
        let stars = (0..<3_200).map { index -> GPUInstance in
            let a = SkyStableHash.mix(UInt64(index) &+ 0xAE01)
            let b = SkyStableHash.mix(a)
            let x = Float(a & 0xffff) / 65535
            var y = Float(b & 0xffff) / 65535
            // A loose inclined dust lane adds density, not a uniform dot texture.
            if index > 2300 { y = fmod(x * 0.55 + 0.18 + y * 0.22, 1) }
            let bright = index.isMultiple(of: 137)
            let radius: Float = bright ? 1.65 : (index.isMultiple(of: 5) ? 0.85 : 0.48)
            let alpha: Float = bright ? 0.82 : (index.isMultiple(of: 5) ? 0.50 : 0.24)
            let color = index.isMultiple(of: 7) ? SIMD4<Float>(1, 0.85, 0.69, alpha) : SIMD4<Float>(0.76, 0.85, 1, alpha)
            return GPUInstance(position: SIMD2(x, y), color0: color, color1: color, color2: color,
                               size: radius, flags: 0x800 | (bright ? 0x1000 : 0), turbulence: bright ? 0.65 : 0.15)
        }
        let dust = (0..<32).map { index -> GPUInstance in
            let a = SkyStableHash.mix(UInt64(index) &+ 0xAE0D)
            let x = Float(a & 0xffff) / 65535
            let y = x * 0.55 + 0.20 + Float((a >> 16) & 255) / 1800
            let color = index.isMultiple(of: 4) ? SIMD4<Float>(0.36, 0.24, 0.19, 0.075) : SIMD4<Float>(0.16, 0.24, 0.39, 0.085)
            return GPUInstance(position: SIMD2(x, y), color0: color, color1: color, color2: color,
                               size: Float(65 + a % 80), flags: 0x800 | 0x2000, turbulence: 0.08)
        }
        return dust + stars
    }

    private func encodeInstances(
        _ encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        buffer: MTLBuffer?,
        count: Int,
        uniforms: inout Uniforms
    ) {
        guard let buffer, count > 0 else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: count)
    }

    private func encodeLines(
        _ encoder: MTLRenderCommandEncoder,
        buffer: MTLBuffer?,
        count: Int,
        uniforms: inout Uniforms
    ) {
        guard let buffer, count > 0 else { return }
        encoder.setRenderPipelineState(linePipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: count)
    }

    private static func pipeline(
        device: MTLDevice,
        view: MTKView,
        vertex: MTLFunction,
        fragment: MTLFunction,
        additive: Bool
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = additive ? .sourceAlpha : .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
