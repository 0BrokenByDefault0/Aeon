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
    private var animateSelection = true
    private var spectrum = SpectrumLevels.zero
    private var camera = SkyCameraState.home
    private var starBuffer: MTLBuffer?
    private var glowBuffer: MTLBuffer?
    private let backdrop: [GPUInstance] = SkyRenderer.makeBackdrop()
    private var lineBuffer: MTLBuffer?
    private var planetBuffer: MTLBuffer?
    private var selectedPlanetBuffer: MTLBuffer?
    private var selectedPlanetTexture: MTLTexture?
    private var starCount = 0
    private var glowCount = 0
    private var lineCount = 0
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
            time: Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 10_000)),
            spectrum: SIMD4(spectrum.low, spectrum.mid, spectrum.high, 0)
        )
        encodeInstances(encoder, pipeline: glowPipeline, buffer: glowBuffer, count: glowCount, uniforms: &uniforms)
        encodeLines(encoder, buffer: lineBuffer, count: lineCount, uniforms: &uniforms)
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
        let selectedStarID = stars.first { $0.albumID == selectedID }?.albumID
        let selectedConstellation = constellations.first { constellation in
            constellation.id == selectedID
                || (selectedStarID.map { constellation.albumIDs.contains($0) } ?? false)
        }
        let constellationMemberIDs = Set(selectedConstellation?.albumIDs ?? [])
        let planetMemberIDs = Set(selectedPlanet?.members.map(\.albumID) ?? [])
        let hasSelection = selectedPlanet != nil || selectedStarID != nil || selectedConstellation != nil
        let playingCoordinate = stars.first { $0.albumID == playingStarID }?.coordinate
        let albumInstances = stars.map { star in
            let isPlanetMember = planetMemberIDs.contains(star.albumID)
            let isConstellationMember = constellationMemberIDs.contains(star.albumID)
            let isSelectedStar = star.albumID == selectedStarID
            let isHighlighted = isPlanetMember || isConstellationMember || isSelectedStar
            let isPlaying = star.albumID == playingStarID
            let nearPlaying: Bool
            if let playingCoordinate {
                let dx = Double(star.coordinate.x) - Double(playingCoordinate.x)
                let dy = Double(star.coordinate.y) - Double(playingCoordinate.y)
                nearPlaying = dx * dx + dy * dy <= 810_000
            } else {
                nearPlaying = false
            }
            let alpha: Float = !hasSelection || isHighlighted ? 1 : 0.38
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
                // Also drawable pixels, and multiplied by `albumScale` (0.70-2.20) in the
                // shader. Kept clear of the backdrop's largest layer at every zoom so a
                // charted album always outranks decoration.
                size: isSelectedStar ? 8 : (isConstellationMember ? 6.5 : Float(5 + (isPlaying ? 1 : 0))),
                flags: (isPlaying ? 0x200 : 0) | (nearPlaying ? 0x400 : 0)
                    | (isHighlighted && animateSelection ? 0x1000 : 0),
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
            selectedPlanetBuffer = nil
            selectedPlanetTexture = nil
            selectedPlanetCount = 0
            return
        }
        selectedPlanetBuffer = makeBuffer([planetInstance(selected, selected: true)])
        selectedPlanetCount = 1
        selectedPlanetTexture = makeTexture(for: selected)
    }

    private func rebuildStaticLineBuffer() {
        let starByID = Dictionary(uniqueKeysWithValues: stars.map { ($0.albumID, $0) })
        let selectedStarID = stars.first { $0.albumID == selectedID }?.albumID
        let selectedConstellationID = constellations.first { constellation in
            constellation.id == selectedID
                || (selectedStarID.map { constellation.albumIDs.contains($0) } ?? false)
        }?.id
        var lines: [GPULine] = []
        lines.reserveCapacity(constellations.reduce(0) { $0 + $1.figureSegments.count * 2 })
        for constellation in constellations {
            let selected = constellation.id == selectedConstellationID
            for segment in constellation.figureSegments {
                guard let from = starByID[segment.fromAlbumID], let to = starByID[segment.toAlbumID] else { continue }
                let dx = Int64(from.coordinate.x) - Int64(to.coordinate.x)
                let dy = Int64(from.coordinate.y) - Int64(to.coordinate.y)
                guard dx * dx + dy * dy <= Int64(SkyComposer.starSpacing * 6) * Int64(SkyComposer.starSpacing * 6) else { continue }
                let alpha: Float = selected ? 0.62 : (selectedConstellationID == nil ? 0.26 : 0.10)
                let color = SIMD4<Float>(selected ? 0.72 : 0.49, selected ? 0.80 : 0.56, selected ? 0.96 : 0.68, alpha)
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
        //
        // `size` is a half-extent in DRAWABLE PIXELS, not points, because the shader
        // divides by `uniforms.viewport`, which is `view.drawableSize`. The first pass
        // used 0.45-0.95, which is a third of a point on a 3x screen: the whole backdrop
        // rasterised to almost nothing and a small library looked like a rendering
        // failure rather than a sky. These values are sized for 2x/3x devices.
        let stars = (0..<2_200).map { index in
            let a = SkyStableHash.mix(UInt64(index) &+ 0xAE01)
            let b = SkyStableHash.mix(a)
            let layer = index % 3
            let x = Float(a & 0xffff) / Float(0xffff)
            let y = Float(b & 0xffff) / Float(0xffff)
            let radius: Float = layer == 0 ? 1.3 : (layer == 1 ? 1.9 : 2.7)
            let alpha: Float = layer == 0 ? 0.20 : (layer == 1 ? 0.32 : 0.46)
            return GPUInstance(position: SIMD2(x, y), color0: SIMD4(0.91, 0.93, 0.96, alpha),
                               color1: SIMD4(0.91, 0.93, 0.96, alpha), color2: SIMD4(0.91, 0.93, 0.96, alpha),
                               size: radius, flags: 0x800, turbulence: Float(layer + 1) * 0.25)
        }
        let haze = (0..<180).map { index in
            let a = SkyStableHash.mix(UInt64(index) &+ 0xAE0D)
            let b = SkyStableHash.mix(a)
            let x = Float(a & 0xffff) / Float(0xffff)
            let y = Float(b & 0xffff) / Float(0xffff)
            let cool = index.isMultiple(of: 3)
            let color = cool ? SIMD4<Float>(0.25, 0.37, 0.62, 0.026) : SIMD4<Float>(0.62, 0.34, 0.28, 0.018)
            return GPUInstance(position: SIMD2(x, y), color0: color, color1: color, color2: color,
                               size: Float(18 + Int(a % 34)), flags: 0x800 | 0x2000,
                               turbulence: Float(index % 4 + 1) * 0.13)
        }
        return haze + stars
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
