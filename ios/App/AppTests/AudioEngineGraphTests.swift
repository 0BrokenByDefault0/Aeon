import XCTest
@testable import App

final class AudioEngineGraphTests: XCTestCase {
    func testConfiguredGraphStartsTransparent() throws {
        let graph = AudioEngineGraph()
        try graph.configure()

        XCTAssertTrue(graph.defaultState.eqBypassed)
        XCTAssertEqual(graph.defaultState.masterVolume, 1, accuracy: 0.000001)
        XCTAssertEqual(graph.defaultState.replayGainA, 1, accuracy: 0.000001)
        XCTAssertEqual(graph.defaultState.replayGainB, 1, accuracy: 0.000001)
        XCTAssertEqual(graph.processorKinds, [.programMixer, .equalizer])
    }

    func testSettingEQMakesItsBypassStateObservable() throws {
        let graph = AudioEngineGraph()
        try graph.configure()

        try graph.setEQ(enabled: true, bands: [EQBand(frequency: 1_000, q: 1, gainDB: 3)])

        XCTAssertFalse(graph.defaultState.eqBypassed)
    }
}
