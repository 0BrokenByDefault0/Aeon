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
    private let selectedPlanetPipeline: MTLRenderPipelineState
    private let generator = PlanetTextureGenerator()

    private var stars: [SkyStar] = []
    private var planets: [SkyPlanet] = []
    private var constellations: [SkyConstellation] = []
    private var selectedID: String?
    private var playingStarID: String?
    private var spectrum = SpectrumLevels.zero
    private var camera = SkyCameraState.home
    private var starBuffer: MTLBuffer?
    private var glowBuffer: MTLBuffer?
    private let backdrop: [GPUInstance] = SkyRenderer.makeBackdrop()
    private var lineBuffer: MTLBuffer?
    private var traceBuffer: MTLBuffer?
    private var planetBuffer: MTLBuffer?
    private var selectedPlanetBuffer: MTLBuffer?
    private var selectedPlanetTexture: MTLTexture?
    private var starCount = 0
    private var glowCount = 0
    private var lineCount = 0
    private var traceCount = 0
    private var planetCount = 0
    private var selectedPlanetCount = 0
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
              let planetFragment = library.makeFunction(name: "skyPlanetFragment"),
              let textureFragment = library.makeFunction(name: "skyPlanetTextureFragment") else { return nil }
        self.device = device
        commandQueue = queue
        do {
            starPipeline = try Self.pipeline(device: device, view: view, vertex: vertex, fragment: starFragment, additive: true)
            glowPipeline = try Self.pipeline(device: device, view: view, vertex: vertex, fragment: glowFragment, additive: true)
            linePipeline = try Self.pipeline(device: device, view: view, vertex: lineVertex, fragment: lineFragment, additive: true)
            planetPipeline = try Self.pipeline(device: device, view: view, vertex: vertex, fragment: planetFragment, additive: false)
            selectedPlanetPipeline = try Self.pipeline(device: device, view: view, vertex: vertex, fragment: textureFragment, additive: false)
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
        spectrum: SpectrumLevels = .zero
    ) {
        let catalogueChanged = stars != catalogue.stars || planets != catalogue.planets || constellations != catalogue.constellations || starBuffer == nil
        let selectionChanged = selectedID != camera.selectedID || self.playingStarID != playingStarID
        let spectrumChanged = self.spectrum != spectrum
        self.camera = camera
        self.spectrum = spectrum
        guard catalogueChanged || selectionChanged || spectrumChanged else { return }
        if catalogueChanged {
            stars = catalogue.stars
            planets = catalogue.planets
            constellations = catalogue.constellations
            rebuildStaticLineBuffer()
            stats.catalogueUploads += 1
        }
        selectedID = camera.selectedID
        self.playingStarID = playingStarID
        if catalogueChanged || selectionChanged {
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
            time: Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 10_000)),
            spectrum: SIMD4(spectrum.low, spectrum.mid, spectrum.high, 0)
        )
        encodeInstances(encoder, pipeline: glowPipeline, buffer: glowBuffer, count: glowCount, uniforms: &uniforms)
        encodeLines(encoder, buffer: lineBuffer, count: lineCount, uniforms: &uniforms)
        encodeLines(encoder, buffer: traceBuffer, count: traceCount, uniforms: &uniforms)
        encodeInstances(encoder, pipeline: starPipeline, buffer: starBuffer, count: starCount, uniforms: &uniforms)
        encodeInstances(encoder, pipeline: planetPipeline, buffer: planetBuffer, count: planetCount, uniforms: &uniforms)
        if let selectedPlanetTexture {
            encoder.setFragmentTexture(selectedPlanetTexture, index: 0)
            encodeInstances(
                encoder,
                pipeline: selectedPlanetPipeline,
                buffer: selectedPlanetBuffer,
                count: selectedPlanetCount,
                uniforms: &uniforms
            )
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        stats.renderedFrames &+= 1
        os_signpost(.end, log: Self.performanceLog, name: "SkyFrame")
    }

    private func rebuildSelectionBuffers() {
        let selectedPlanet = planets.first { $0.id == selectedID }
        let memberIDs = Set(selectedPlanet?.members.map(\.albumID) ?? [])
        let playingCoordinate = stars.first { $0.albumID == playingStarID }?.coordinate
        let albumInstances = stars.map { star in
            let isMember = memberIDs.contains(star.albumID)
            let isPlaying = star.albumID == playingStarID
            let nearPlaying: Bool
            if let playingCoordinate {
                let dx = Double(star.coordinate.x) - Double(playingCoordinate.x)
                let dy = Double(star.coordinate.y) - Double(playingCoordinate.y)
                nearPlaying = dx * dx + dy * dy <= 810_000
            } else {
                nearPlaying = false
            }
            let alpha: Float = selectedPlanet == nil || isMember ? 1 : 0.2
            let classes: [SIMD4<Float>] = [
                SIMD4(0.66, 0.76, 1, alpha), SIMD4(0.84, 0.89, 1, alpha),
                SIMD4(0.96, 0.95, 1, alpha), SIMD4(1, 0.91, 0.77, alpha), SIMD4(1, 0.79, 0.54, alpha)
            ]
            let color = classes[Int(SkyStableHash.value(star.albumID) % UInt64(classes.count))]
            return GPUInstance(
                position: SIMD2(Float(star.coordinate.x), Float(star.coordinate.y)),
                color0: color,
                color1: color,
                color2: color,
                size: Float(3.2 + (isPlaying ? 0.6 : 0)),
                flags: (isPlaying ? 0x200 : 0) | (nearPlaying ? 0x400 : 0),
                turbulence: 0
            )
        }
        let starInstances = backdrop + albumInstances
        starCount = starInstances.count
        starBuffer = makeBuffer(starInstances)
        let glows = albumInstances.map {
            var value = $0
            value.size *= 3.6
            value.color0 *= SIMD4<Float>(0.42, 0.45, 0.55, 0.2)
            value.flags |= 1
            return value
        }
        glowBuffer = makeBuffer(glows)
        glowCount = glows.count

        rebuildPlanetBuffers()
        guard let selected = selectedPlanet else {
            traceBuffer = nil
            traceCount = 0
            selectedPlanetBuffer = nil
            selectedPlanetTexture = nil
            selectedPlanetCount = 0
            return
        }
        let starByID = Dictionary(uniqueKeysWithValues: stars.map { ($0.albumID, $0) })
        var traces: [GPULine] = []
        traces.reserveCapacity(selected.members.count * 2)
        for member in selected.members {
            guard let star = starByID[member.albumID] else { continue }
            let color = SIMD4<Float>(0.64, 0.77, 0.94, 0.56)
            traces.append(GPULine(position: SIMD2(Float(selected.coordinate.x), Float(selected.coordinate.y)), color: color))
            traces.append(GPULine(position: SIMD2(Float(star.coordinate.x), Float(star.coordinate.y)), color: color))
        }
        traceCount = traces.count
        traceBuffer = makeBuffer(traces)
        selectedPlanetBuffer = makeBuffer([planetInstance(selected, selected: true)])
        selectedPlanetCount = 1
        selectedPlanetTexture = makeTexture(for: selected)
    }

    private func rebuildStaticLineBuffer() {
        let starByID = Dictionary(uniqueKeysWithValues: stars.map { ($0.albumID, $0) })
        var lines: [GPULine] = []
        lines.reserveCapacity(constellations.reduce(0) { $0 + $1.figureSegments.count * 2 })
        for constellation in constellations {
            for segment in constellation.figureSegments {
                guard let from = starByID[segment.fromAlbumID], let to = starByID[segment.toAlbumID] else { continue }
                let color = SIMD4<Float>(0.49, 0.56, 0.68, 0.28)
                lines.append(GPULine(position: SIMD2(Float(from.coordinate.x), Float(from.coordinate.y)), color: color))
                lines.append(GPULine(position: SIMD2(Float(to.coordinate.x), Float(to.coordinate.y)), color: color))
            }
        }
        lineCount = lines.count
        lineBuffer = makeBuffer(lines)
    }

    private func rebuildPlanetBuffers() {
        let unselected = planets.filter { $0.id != selectedID }.map { planetInstance($0, selected: false) }
        planetCount = unselected.count
        planetBuffer = makeBuffer(unselected)
    }

    private func planetInstance(_ planet: SkyPlanet, selected: Bool) -> GPUInstance {
        let colors = planet.descriptor.bandColors
        func vector(_ index: Int) -> SIMD4<Float> {
            let color = colors.isEmpty ? SkyColor(red: 120, green: 132, blue: 150) : colors[index % colors.count]
            return SIMD4(Float(color.red) / 255, Float(color.green) / 255, Float(color.blue) / 255, 1)
        }
        return GPUInstance(
            position: SIMD2(Float(planet.coordinate.x), Float(planet.coordinate.y)),
            color0: vector(0),
            color1: vector(1),
            color2: vector(2),
            size: selected ? 46 : 28,
            flags: UInt32(selected ? 3 : 2) | (planet.descriptor.hasRings ? 0x100 : 0),
            turbulence: Float(planet.descriptor.turbulence) / 1024
        )
    }

    private func makeTexture(for planet: SkyPlanet) -> MTLTexture? {
        let bytes = generator.rgbaTexture(seed: planet.seed, descriptor: planet.descriptor)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: PlanetTextureGenerator.width,
            height: PlanetTextureGenerator.height,
            mipmapped: false
        )
        descriptor.usage = MTLTextureUsage.shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        bytes.withUnsafeBytes { source in
            texture.replace(
                region: MTLRegionMake2D(0, 0, PlanetTextureGenerator.width, PlanetTextureGenerator.height),
                mipmapLevel: 0,
                withBytes: source.baseAddress!,
                bytesPerRow: PlanetTextureGenerator.width * 4
            )
        }
        return texture
    }

    private func makeBuffer<Element>(_ values: [Element]) -> MTLBuffer? {
        guard !values.isEmpty else { return nil }
        return values.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: address, length: bytes.count, options: .storageModeShared)
        }
    }

    private static func makeBackdrop() -> [GPUInstance] {
        // Fixed seed: this is one sky, not a fresh decorative scatter every launch.
        (0..<1_400).map { index in
            let a = SkyStableHash.mix(UInt64(index) &+ 0xAE01)
            let b = SkyStableHash.mix(a)
            let layer = index % 3
            let x = Float(a & 0xffff) / Float(0xffff)
            let y = Float(b & 0xffff) / Float(0xffff)
            let radius: Float = layer == 0 ? 0.45 : (layer == 1 ? 0.70 : 0.95)
            let alpha: Float = layer == 0 ? 0.08 : (layer == 1 ? 0.14 : 0.19)
            return GPUInstance(position: SIMD2(x, y), color0: SIMD4(0.91, 0.93, 0.96, alpha),
                               color1: SIMD4(0.91, 0.93, 0.96, alpha), color2: SIMD4(0.91, 0.93, 0.96, alpha),
                               size: radius, flags: 0x800, turbulence: Float(layer + 1) * 0.25)
        }
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
