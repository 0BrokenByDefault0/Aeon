import AVFoundation

enum AudioSlot: Hashable {
    case a
    case b
}

enum AudioGraphProcessorKind: Equatable {
    case programMixer
    case equalizer
}

struct AudioEngineGraphDefaultState: Equatable {
    let eqBypassed: Bool
    let masterVolume: Float
    let replayGainA: Float
    let replayGainB: Float
}

enum AudioEngineGraphError: Error, Equatable {
    case noFileLoaded(AudioSlot)
    case invalidSeekTime(Double)
    case seekPastEnd
    case tooManyEQBands(Int)
    case invalidEQBand(index: Int, parameter: String)
}

final class AudioEngineGraph {
    private static let maximumEQBands = 10
    private static let validEQFrequency = 20.0...24_000.0
    private static let validEQGain = -96.0...24.0
    private static let validEQBandwidth = 0.05...5.0

    private(set) var engine: AVAudioEngine
    private(set) var playerA: AVAudioPlayerNode
    private(set) var playerB: AVAudioPlayerNode
    private(set) var programMixer: AVAudioMixerNode
    private(set) var equalizer: AVAudioUnitEQ

    private var files: [AudioSlot: AVAudioFile] = [:]
    private var isConfigured = false
    private var masterVolume: Float = 1
    private var replayGainA: Float = 1
    private var replayGainB: Float = 1
    private var eqEnabled = false
    private var eqBands: [EQBand] = []
    private let outputFormatProvider: (() -> AVAudioFormat?)?

    init(outputFormatProvider: (() -> AVAudioFormat?)? = nil) {
        engine = AVAudioEngine()
        playerA = AVAudioPlayerNode()
        playerB = AVAudioPlayerNode()
        programMixer = AVAudioMixerNode()
        equalizer = AVAudioUnitEQ(numberOfBands: AudioEngineGraph.maximumEQBands)
        equalizer.bypass = true
        self.outputFormatProvider = outputFormatProvider
    }

    var defaultState: AudioEngineGraphDefaultState {
        AudioEngineGraphDefaultState(
            eqBypassed: equalizer.bypass,
            masterVolume: engine.mainMixerNode.outputVolume,
            replayGainA: playerA.volume,
            replayGainB: playerB.volume
        )
    }

    var processorKinds: [AudioGraphProcessorKind] { [.programMixer, .equalizer] }

    var configuredEQBands: [EQBand] { eqBands }

    static func scheduleFrameCounts(totalFrames: AVAudioFramePosition) -> [AVAudioFrameCount] {
        guard totalFrames > 0 else { return [] }
        var counts: [AVAudioFrameCount] = []
        var remainingFrames = totalFrames
        let maximumSegmentFrames = AVAudioFramePosition(AVAudioFrameCount.max)
        while remainingFrames > 0 {
            let segmentFrames = min(remainingFrames, maximumSegmentFrames)
            counts.append(AVAudioFrameCount(segmentFrames))
            remainingFrames -= segmentFrames
        }
        return counts
    }

    func configure() throws {
        guard !isConfigured else { return }

        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(programMixer)
        engine.attach(equalizer)

        programMixer.outputVolume = 1
        playerA.volume = replayGainA
        playerB.volume = replayGainB
        engine.mainMixerNode.outputVolume = masterVolume
        applyEQBands()
        equalizer.bypass = !eqEnabled

        engine.connect(playerA, to: programMixer, format: nil)
        engine.connect(playerB, to: programMixer, format: nil)
        engine.connect(programMixer, to: equalizer, format: nil)
        engine.connect(equalizer, to: engine.mainMixerNode, format: nil)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        isConfigured = true
    }

    func open(url: URL, in slot: AudioSlot) throws -> AVAudioFile {
        try configure()
        let file = try AVAudioFile(forReading: url)
        files[slot] = file
        return file
    }

    func play(slot: AudioSlot, fromFrame: AVAudioFramePosition?) throws {
        try configure()
        guard let file = files[slot] else { throw AudioEngineGraphError.noFileLoaded(slot) }

        let startFrame: AVAudioFramePosition?
        if let requestedFrame = fromFrame {
            guard requestedFrame >= 0 else {
                throw AudioEngineGraphError.invalidSeekTime(Double(requestedFrame) / file.processingFormat.sampleRate)
            }
            guard requestedFrame < file.length else { throw AudioEngineGraphError.seekPastEnd }
            startFrame = requestedFrame
        } else {
            startFrame = nil
        }

        let player = player(for: slot)
        player.stop()
        if let startFrame {
            scheduleSegments(file: file, startingFrame: startFrame, on: player)
        } else {
            player.scheduleFile(file, at: nil, completionHandler: nil)
        }

        if !engine.isRunning { try engine.start() }
        player.play()
    }

    func pause() {
        playerA.pause()
        playerB.pause()
    }

    func stop() {
        playerA.stop()
        playerB.stop()
        engine.stop()
    }

    func seek(slot: AudioSlot, to seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0 else { throw AudioEngineGraphError.invalidSeekTime(seconds) }
        guard let file = files[slot] else { throw AudioEngineGraphError.noFileLoaded(slot) }
        let sampleRate = file.processingFormat.sampleRate
        let frameValue = seconds * sampleRate
        guard sampleRate.isFinite,
              sampleRate > 0,
              frameValue.isFinite,
              frameValue <= Double(AVAudioFramePosition.max) else {
            throw AudioEngineGraphError.invalidSeekTime(seconds)
        }
        let frame = AVAudioFramePosition(frameValue.rounded(.down))
        guard frame < file.length else { throw AudioEngineGraphError.seekPastEnd }
        try play(slot: slot, fromFrame: frame)
    }

    func setMasterVolume(_ linear: Float) {
        masterVolume = linear.isFinite && (0...1).contains(linear) ? linear : 1
        engine.mainMixerNode.outputVolume = masterVolume
    }

    func setReplayGain(_ scalar: Float, slot: AudioSlot) {
        let transparentScalar = scalar.isFinite && scalar >= 0 ? scalar : 1
        switch slot {
        case .a:
            replayGainA = transparentScalar
            playerA.volume = transparentScalar
        case .b:
            replayGainB = transparentScalar
            playerB.volume = transparentScalar
        }
    }

    func setEQ(enabled: Bool, bands: [EQBand]) throws {
        try validateEQBands(bands)
        try configure()
        eqEnabled = enabled
        eqBands = bands
        applyEQBands()
        equalizer.bypass = !enabled
    }

    func outputDescriptor() -> OutputFormatDescriptor {
        if let outputFormatProvider {
            guard let format = outputFormatProvider(),
                  format.sampleRate.isFinite,
                  format.sampleRate > 0,
                  format.channelCount > 0 else {
                return unknownOutputDescriptor()
            }
            return descriptor(format: format, output: nil)
        }

        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        let formatSampleRate = hardwareFormat.sampleRate.isFinite && hardwareFormat.sampleRate > 0
            ? hardwareFormat.sampleRate
            : nil
        let sessionSampleRate = session.sampleRate.isFinite && session.sampleRate > 0
            ? session.sampleRate
            : nil
        let sampleRate = formatSampleRate ?? sessionSampleRate
        let formatChannelCount = hardwareFormat.channelCount > 0 ? Int(hardwareFormat.channelCount) : nil
        let routeChannelCount: Int?
        if let channels = output?.channels, !channels.isEmpty {
            routeChannelCount = channels.count
        } else {
            routeChannelCount = nil
        }
        let channelCount = formatChannelCount ?? routeChannelCount

        guard output != nil || sampleRate != nil || channelCount != nil else {
            return unknownOutputDescriptor()
        }

        return OutputFormatDescriptor(
            sampleRate: sampleRate ?? 0,
            channelCount: channelCount ?? 0,
            route: RouteDescriptor(
                kind: routeKind(for: output?.portType),
                name: output?.portName ?? "Unknown output",
                sampleRate: sampleRate,
                channelCount: channelCount
            )
        )
    }

    func rebuild() throws {
        stop()
        engine.detach(playerA)
        engine.detach(playerB)
        engine.detach(programMixer)
        engine.detach(equalizer)

        engine = AVAudioEngine()
        playerA = AVAudioPlayerNode()
        playerB = AVAudioPlayerNode()
        programMixer = AVAudioMixerNode()
        equalizer = AVAudioUnitEQ(numberOfBands: Self.maximumEQBands)
        isConfigured = false
        try configure()
    }

    private func player(for slot: AudioSlot) -> AVAudioPlayerNode {
        switch slot {
        case .a: return playerA
        case .b: return playerB
        }
    }

    private func applyEQBands() {
        for (index, filter) in equalizer.bands.enumerated() {
            guard index < eqBands.count else {
                filter.bypass = true
                continue
            }
            let band = eqBands[index]
            filter.filterType = .parametric
            filter.frequency = Float(band.frequency)
            filter.bandwidth = bandwidth(forQ: band.q)
            filter.gain = Float(band.gainDB)
            filter.bypass = false
        }
    }

    private func validateEQBands(_ bands: [EQBand]) throws {
        guard bands.count <= Self.maximumEQBands else {
            throw AudioEngineGraphError.tooManyEQBands(bands.count)
        }
        for (index, band) in bands.enumerated() {
            guard band.frequency.isFinite, Self.validEQFrequency.contains(band.frequency) else {
                throw AudioEngineGraphError.invalidEQBand(index: index, parameter: "frequency")
            }
            guard band.q.isFinite, band.q > 0 else {
                throw AudioEngineGraphError.invalidEQBand(index: index, parameter: "q")
            }
            let bandwidth = Double(bandwidth(forQ: band.q))
            guard bandwidth.isFinite, Self.validEQBandwidth.contains(bandwidth) else {
                throw AudioEngineGraphError.invalidEQBand(index: index, parameter: "q")
            }
            guard band.gainDB.isFinite, Self.validEQGain.contains(band.gainDB) else {
                throw AudioEngineGraphError.invalidEQBand(index: index, parameter: "gainDB")
            }
        }
    }

    private func scheduleSegments(
        file: AVAudioFile,
        startingFrame: AVAudioFramePosition,
        on player: AVAudioPlayerNode
    ) {
        var nextFrame = startingFrame
        for segmentFrameCount in Self.scheduleFrameCounts(totalFrames: file.length - startingFrame) {
            player.scheduleSegment(
                file,
                startingFrame: nextFrame,
                frameCount: segmentFrameCount,
                at: nil,
                completionHandler: nil
            )
            nextFrame += AVAudioFramePosition(segmentFrameCount)
        }
    }

    private func descriptor(
        format: AVAudioFormat,
        output: AVAudioSessionPortDescription?
    ) -> OutputFormatDescriptor {
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        return OutputFormatDescriptor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            route: RouteDescriptor(
                kind: routeKind(for: output?.portType),
                name: output?.portName ?? "Unknown output",
                sampleRate: sampleRate,
                channelCount: channelCount
            )
        )
    }

    private func unknownOutputDescriptor() -> OutputFormatDescriptor {
        OutputFormatDescriptor(
            sampleRate: 0,
            channelCount: 0,
            route: RouteDescriptor(
                kind: .unknown,
                name: "Unknown output",
                sampleRate: nil,
                channelCount: nil
            )
        )
    }

    private func routeKind(for portType: AVAudioSession.Port?) -> AudioRouteKind {
        switch portType {
        case .builtInSpeaker?, .builtInReceiver?: return .speaker
        case .headphones?, .headsetMic?, .lineOut?: return .wired
        case .bluetoothA2DP?, .bluetoothHFP?: return .bluetooth
        case .airPlay?: return .airPlay
        case .usbAudio?: return .usb
        default: return .unknown
        }
    }

    private func bandwidth(forQ q: Double) -> Float {
        let safeQ = max(q, Double.leastNonzeroMagnitude)
        return Float(2 * asinh(1 / (2 * safeQ)) / log(2))
    }
}
