import XCTest
@testable import App

final class ReplayGainAndEQTests: XCTestCase {
    func testReplayGainOffIsUnity() {
        XCTAssertEqual(
            replayGainScalar(
                mode: .off,
                values: .init(trackGainDB: -7, albumGainDB: -5, trackPeak: 1, albumPeak: 1),
                preampDB: 6
            ),
            1,
            accuracy: 0.000001
        )
    }

    func testTrackReplayGainUsesDBToLinearConversion() {
        let scalar = replayGainScalar(
            mode: .track,
            values: .init(trackGainDB: -6, albumGainDB: nil, trackPeak: nil, albumPeak: nil),
            preampDB: 0
        )

        XCTAssertEqual(scalar, Float(pow(10.0, -6.0 / 20.0)), accuracy: 0.00001)
    }

    func testSelectedReplayGainWithoutMetadataIsUnity() {
        XCTAssertEqual(
            replayGainScalar(mode: .album, values: .empty, preampDB: 6),
            1,
            accuracy: 0.000001
        )
    }

    func testNonfiniteReplayGainFallsBackToUnity() {
        XCTAssertEqual(
            replayGainScalar(
                mode: .track,
                values: .init(trackGainDB: .infinity, albumGainDB: nil, trackPeak: nil, albumPeak: nil),
                preampDB: 0
            ),
            1,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            replayGainScalar(
                mode: .album,
                values: .init(trackGainDB: nil, albumGainDB: -3, trackPeak: nil, albumPeak: nil),
                preampDB: .nan
            ),
            1,
            accuracy: 0.000001
        )
    }
}
