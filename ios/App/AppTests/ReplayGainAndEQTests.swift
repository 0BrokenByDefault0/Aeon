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

    func testParsesReplayGainFieldsCaseInsensitively() {
        let values = ReplayGainValues.parse(fields: [
            "replaygain_track_gain": "-7.25 dB",
            "REPLAYGAIN_ALBUM_GAIN": "-5.5 DB",
            "replaygain_track_peak": "0.94",
            "replaygain_album_peak": "1.01"
        ])

        XCTAssertEqual(values.trackGainDB, -7.25)
        XCTAssertEqual(values.albumGainDB, -5.5)
        XCTAssertEqual(values.trackPeak, 0.94)
        XCTAssertEqual(values.albumPeak, 1.01)
    }

    func testPeakOnlyProducesWarningAndDoesNotLimitGain() {
        let values = ReplayGainValues(
            trackGainDB: 6,
            albumGainDB: nil,
            trackPeak: 0.75,
            albumPeak: nil
        )

        XCTAssertTrue(replayGainPeakWarning(mode: .track, values: values, preampDB: 0))
        XCTAssertEqual(
            replayGainScalar(mode: .track, values: values, preampDB: 0),
            Float(pow(10, 6.0 / 20.0)),
            accuracy: 0.00001
        )
    }

    func testReadsBoundedID3ReplayGainMetadata() throws {
        let value = Data("REPLAYGAIN_TRACK_GAIN\0-8.0 dB".utf8)
        let payload = Data([3]) + value
        let size = payload.count
        let frame = Data("TXXX".utf8) + Data([
            UInt8((size >> 24) & 0xff), UInt8((size >> 16) & 0xff),
            UInt8((size >> 8) & 0xff), UInt8(size & 0xff), 0, 0
        ]) + payload
        let tagSize = frame.count
        let header = Data("ID3".utf8) + Data([3, 0, 0,
            UInt8((tagSize >> 21) & 0x7f), UInt8((tagSize >> 14) & 0x7f),
            UInt8((tagSize >> 7) & 0x7f), UInt8(tagSize & 0x7f)
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try (header + frame).write(to: url, options: .atomic)

        XCTAssertEqual(ReplayGainMetadataReader.read(url: url).trackGainDB, -8)
    }
}
