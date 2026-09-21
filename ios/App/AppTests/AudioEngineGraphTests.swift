import AVFoundation
import XCTest
@testable import App

final class AudioEngineGraphTests: XCTestCase {
    func testOfflineUnityPathKeepsFramesAndNullsBelowMinus100DBFS() throws {
        let input = (0..<16_384).map { index -> Float in
            let time = Double(index) / 48_000
            return Float(0.2 * sin(2 * .pi * 997 * time) + 0.1 * cos(2 * .pi * 7_013 * time))
        }
        let rendered = try renderOffline(input, bands: [], enabled: false)
        XCTAssertEqual(rendered.count, input.count)
        let residual = zip(rendered, input).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(residual, 0.00001, "Same-rate float32 app path, zero alignment offset")
    }

    func testOfflineLegacyBellMatchesIndependentLowFrequencyReference() throws {
        var impulse = [Float](repeating: 0, count: 16_384)
        impulse[0] = 0.25
        let rendered = try renderOffline(impulse,
            bands: [EQBand(frequency: 1_000, q: 1, gainDB: 6)], enabled: true)
        // Independent RBJ bell calculation (https://www.w3.org/TR/audio-eq-cookbook/),
        // not the production width/gain helper.
        // Scope: 48 kHz, 1 kHz bell, Q=1, +6 dB, existing -6 dB makeup.
        // This is not evidence for near-Nyquist filters or device output.
        let a = pow(10.0, 6.0 / 40)
        let omega = 2 * Double.pi * 1_000 / 48_000
        let alpha = sin(omega) / 2
        let numerator = [1 + alpha * a, -2 * cos(omega), 1 - alpha * a]
        let denominator = [1 + alpha / a, -2 * cos(omega), 1 - alpha / a]
        func magnitude(_ coefficients: [Double], at w: Double) -> Double {
            let real = coefficients[0] + coefficients[1] * cos(w) + coefficients[2] * cos(2 * w)
            let imaginary = -coefficients[1] * sin(w) - coefficients[2] * sin(2 * w)
            return hypot(real, imaginary)
        }
        for frequency in [100.0, 250, 500, 1_000, 2_000, 4_000] {
            let w = 2 * Double.pi * frequency / 48_000
            var real = 0.0, imaginary = 0.0
            for (index, sample) in rendered.enumerated() {
                real += Double(sample) * cos(w * Double(index))
                imaginary -= Double(sample) * sin(w * Double(index))
            }
            let measured = 20 * log10(hypot(real, imaginary) / 0.25)
            let expected = 20 * log10(magnitude(numerator, at: w) / magnitude(denominator, at: w)) - 6
            XCTAssertEqual(measured, expected, accuracy: 0.1, "\(frequency) Hz")
        }
    }

    private func renderOffline(_ input: [Float], bands: [EQBand], enabled: Bool) throws -> [Float] {
        let graph = makeGraph()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try graph.configure()
        // Explicit same-rate processor fixture; no source decoding or hardware claim.
        graph.engine.connect(graph.playerA, to: graph.programMixer, fromBus: 0, toBus: 0, format: format)
        graph.engine.connect(graph.programMixer, to: graph.equalizer, format: format)
        graph.engine.connect(graph.equalizer, to: graph.engine.mainMixerNode, format: format)
        try graph.setEQ(enabled: enabled, bands: bands)
        try graph.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1_024)
        XCTAssertEqual(graph.outputDescriptor().processingSampleRate, 48_000)
        defer { graph.engine.stop(); graph.engine.disableManualRenderingMode() }
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.count)))
        source.frameLength = source.frameCapacity
        for channel in 0..<2 {
            for index in input.indices { source.floatChannelData![channel][index] = input[index] }
        }
        graph.playerA.scheduleBuffer(source)
        try graph.engine.start()
        graph.playerA.play()
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        var result: [Float] = []
        result.reserveCapacity(input.count)
        var unavailable = 0
        var channelResidual: Float = 0
        while result.count < input.count {
            let requested = AVAudioFrameCount(min(1_024, input.count - result.count))
            let status = try graph.engine.renderOffline(requested, to: buffer)
            if status == .cannotDoInCurrentContext, unavailable < 8 { unavailable += 1; continue }
            guard status == .success, buffer.frameLength == requested else {
                throw NSError(domain: "AeonOfflineFixture", code: Int(status.rawValue),
                    userInfo: [NSLocalizedDescriptionKey: "Offline render did not return the requested frames"])
            }
            for index in 0..<Int(buffer.frameLength) {
                let left = buffer.floatChannelData![0][index]
                let right = buffer.floatChannelData![1][index]
                channelResidual = max(channelResidual, abs(left - right))
                result.append(left)
            }
        }
        XCTAssertLessThanOrEqual(channelResidual, 0.000001)
        return result
    }

    func testUnconfiguredGraphStartsTransparent() {
        let graph = makeGraph()

        XCTAssertTrue(graph.defaultState.eqBypassed)
        XCTAssertEqual(graph.defaultState.masterVolume, 1, accuracy: 0.000001)
        XCTAssertEqual(graph.defaultState.replayGainA, 1, accuracy: 0.000001)
        XCTAssertEqual(graph.defaultState.replayGainB, 1, accuracy: 0.000001)
    }

    func testConfiguredGraphStartsTransparent() throws {
        let graph = makeGraph()
        try graph.configure()

        XCTAssertTrue(graph.defaultState.eqBypassed)
        XCTAssertEqual(graph.defaultState.masterVolume, 1, accuracy: 0.000001)
        XCTAssertEqual(graph.defaultState.replayGainA, 1, accuracy: 0.000001)
        XCTAssertEqual(graph.defaultState.replayGainB, 1, accuracy: 0.000001)
        XCTAssertEqual(graph.engine.attachedNodes.filter { $0 is AVAudioPlayerNode }.count, 2)
        XCTAssertTrue(graph.engine.attachedNodes.contains { $0 === graph.programMixer })
        XCTAssertTrue(graph.engine.attachedNodes.contains { $0 === graph.equalizer })
        XCTAssertTrue(connects(graph.engine, graph.playerA, to: graph.programMixer))
        XCTAssertTrue(connects(graph.engine, graph.playerB, to: graph.programMixer))
        XCTAssertTrue(connects(graph.engine, graph.programMixer, to: graph.equalizer))
        XCTAssertTrue(connects(graph.engine, graph.equalizer, to: graph.engine.mainMixerNode))
        XCTAssertTrue(connects(graph.engine, graph.engine.mainMixerNode, to: graph.engine.outputNode))
    }

    func testSettingEQMakesItsBypassStateObservable() throws {
        let graph = makeGraph()
        try graph.configure()

        try graph.setEQ(enabled: true, bands: [EQBand(frequency: 1_000, q: 1, gainDB: 3)])

        XCTAssertFalse(graph.defaultState.eqBypassed)
    }

    func testRebuildPreservesPersistentEQVolumeAndReplayGain() throws {
        let graph = makeGraph()
        let bands = [EQBand(frequency: 1_000, q: 1, gainDB: -2)]
        graph.setMasterVolume(0.7)
        graph.setReplayGain(0.5, slot: .a)
        graph.setReplayGain(0.6, slot: .b)
        try graph.setEQ(enabled: true, bands: bands)

        try graph.rebuild()

        XCTAssertEqual(graph.defaultState.masterVolume, 0.7, accuracy: 0.000001)
        XCTAssertEqual(graph.defaultState.replayGainA, 0.5, accuracy: 0.000001)
        XCTAssertEqual(graph.defaultState.replayGainB, 0.6, accuracy: 0.000001)
        XCTAssertFalse(graph.defaultState.eqBypassed)
        XCTAssertEqual(graph.configuredEQBands, bands)
    }

    func testInvalidEQBandDoesNotPartiallyCommitState() throws {
        let graph = makeGraph()
        let validBand = EQBand(frequency: 1_000, q: 1, gainDB: 3)
        try graph.setEQ(enabled: true, bands: [validBand])

        XCTAssertThrowsError(try graph.setEQ(enabled: false, bands: [EQBand(frequency: .nan, q: 1, gainDB: 3)]))

        XCTAssertFalse(graph.defaultState.eqBypassed)
        XCTAssertEqual(graph.configuredEQBands, [validBand])
    }

    func testEQBandValidationRejectsOutOfRangeAndNonfiniteParameters() throws {
        let graph = makeGraph()
        let invalidBands = [
            EQBand(frequency: 19.99, q: 1, gainDB: 0),
            EQBand(frequency: 24_001, q: 1, gainDB: 0),
            EQBand(frequency: 1_000, q: 0, gainDB: 0),
            EQBand(frequency: 1_000, q: .infinity, gainDB: 0),
            EQBand(frequency: 1_000, q: 1, gainDB: -96.01),
            EQBand(frequency: 1_000, q: 1, gainDB: 24.01)
        ]

        for band in invalidBands {
            XCTAssertThrowsError(try graph.setEQ(enabled: true, bands: [band]), "Expected \(band) to be rejected")
        }
    }

    func testGraphGainSettersUseUnityForInvalidScalarsAndPreservePositiveReplayGain() throws {
        let graph = makeGraph()
        try graph.configure()

        graph.setMasterVolume(.nan)
        graph.setReplayGain(-1, slot: .a)
        XCTAssertEqual(graph.defaultState.masterVolume, 1, accuracy: 0.000001)
        XCTAssertEqual(graph.defaultState.replayGainA, 1, accuracy: 0.000001)

        graph.setMasterVolume(-0.5)
        XCTAssertEqual(graph.defaultState.masterVolume, 1, accuracy: 0.000001)

        graph.setReplayGain(replayGainScalar(mode: .track, values: .init(trackGainDB: 6, albumGainDB: nil, trackPeak: nil, albumPeak: nil), preampDB: 0), slot: .a)
        XCTAssertEqual(graph.defaultState.replayGainA, Float(pow(10.0, 6.0 / 20.0)), accuracy: 0.000001)
    }

    func testOutputDescriptorUsesUnknownZeroValuesWithoutAHardwareFormat() {
        let graph = AudioEngineGraph(outputFormatProvider: { nil })

        let descriptor = graph.outputDescriptor()

        XCTAssertEqual(descriptor.sampleRate, 0)
        XCTAssertEqual(descriptor.channelCount, 0)
        XCTAssertEqual(descriptor.route.kind, .unknown)
        XCTAssertNil(descriptor.route.sampleRate)
        XCTAssertNil(descriptor.route.channelCount)
    }

    func testBundledWAVSupportsTransportOperationsAndRebuild() throws {
        let graph = makeGraph()
        let file = try graph.open(url: fixtureURL(named: "pcm-48000.wav"), in: .a)
        XCTAssertEqual(file.length, 12_000)

        try graph.play(slot: .a, fromFrame: 0)
        graph.pause()
        try graph.seek(slot: .a, to: 0.01)
        graph.stop()
        try graph.rebuild()
        try graph.play(slot: .a, fromFrame: 480)
        graph.stop()

        XCTAssertTrue(graph.defaultState.eqBypassed)
    }

    func testLongSegmentsDoNotTruncateToUInt32() {
        let overflow = AVAudioFramePosition(AVAudioFrameCount.max) + 17

        XCTAssertEqual(
            AudioEngineGraph.scheduleFrameCounts(totalFrames: overflow),
            [AVAudioFrameCount.max, 17]
        )
    }

    func testInvalidSeekDoesNotStopCurrentNode() throws {
        let graph = makeGraph()
        _ = try graph.open(url: fixtureURL(named: "pcm-48000.wav"), in: .a)
        try graph.play(slot: .a, fromFrame: 0)

        XCTAssertThrowsError(try graph.play(slot: .a, fromFrame: -1))
        XCTAssertThrowsError(try graph.seek(slot: .a, to: Double.greatestFiniteMagnitude))
        XCTAssertTrue(graph.playerA.isPlaying)
    }

    private func makeGraph() -> AudioEngineGraph {
        AudioEngineGraph(outputFormatProvider: {
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        })
    }

    private func fixtureURL(named name: String) -> URL {
        guard let resourceURL = Bundle(for: AudioEngineGraphTests.self).resourceURL else {
            fatalError("AppTests resource bundle is unavailable")
        }
        return resourceURL.appendingPathComponent("audio", isDirectory: true).appendingPathComponent(name)
    }

    private func connects(_ engine: AVAudioEngine, _ source: AVAudioNode, to destination: AVAudioNode) -> Bool {
        engine.outputConnectionPoints(for: source, outputBus: 0).contains { $0.node === destination }
    }
}
