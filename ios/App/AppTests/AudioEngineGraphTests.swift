import XCTest
@testable import App

final class AudioEngineGraphTests: XCTestCase {
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
