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
}

final class AudioEngineGraph {
    private static let maximumEQBands = 10

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

    init() {
        engine = AVAudioEngine()
        playerA = AVAudioPlayerNode()
        playerB = AVAudioPlayerNode()
        programMixer = AVAudioMixerNode()
        equalizer = AVAudioUnitEQ(numberOfBands: AudioEngineGraph.maximumEQBands)
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

        let player = player(for: slot)
        player.stop()
        if let fromFrame {
            let startFrame = max(0, fromFrame)
            guard startFrame < file.length else { throw AudioEngineGraphError.seekPastEnd }
            let remainingFrameCount = file.length - startFrame
            player.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(remainingFrameCount),
                at: nil,
                completionHandler: nil
            )
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
        let frame = AVAudioFramePosition(seconds * file.processingFormat.sampleRate)
        try play(slot: slot, fromFrame: frame)
    }

    func setMasterVolume(_ linear: Float) {
        masterVolume = max(0, min(linear, 1))
        engine.mainMixerNode.outputVolume = masterVolume
    }

    func setReplayGain(_ scalar: Float, slot: AudioSlot) {
        switch slot {
        case .a:
            replayGainA = scalar
            playerA.volume = scalar
        case .b:
            replayGainB = scalar
            playerB.volume = scalar
        }
    }

    func setEQ(enabled: Bool, bands: [EQBand]) throws {
        guard bands.count <= Self.maximumEQBands else {
            throw AudioEngineGraphError.tooManyEQBands(bands.count)
        }
        try configure()
        eqEnabled = enabled
        eqBands = bands
        applyEQBands()
        equalizer.bypass = !enabled
    }

    func outputDescriptor() -> OutputFormatDescriptor {
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : session.sampleRate
        let channelCount = outputFormat.channelCount > 0
            ? Int(outputFormat.channelCount)
            : max(output?.channels.count ?? 0, 1)

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
