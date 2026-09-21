import XCTest
@testable import App

final class ParametricDSPTests: XCTestCase {
    func testOldEQRetainsHistoricalWidthAndIdentity() throws {
        let old = Data(#"{"frequency":1000,"q":1,"gainDB":3}"#.utf8)
        let band = try JSONDecoder().decode(EQBand.self, from: old)
        XCTAssertEqual(band.version, 1)
        XCTAssertEqual(band.type, .bell)
        XCTAssertTrue(band.enabled)
        XCTAssertEqual(try JSONDecoder().decode(EQBand.self, from: JSONEncoder().encode(band)), band)
    }
    func testFilterCentersEndpointsAndNearNyquistAtThreeRates() throws {
        for rate in [44100.0, 48000, 96000] {
            for frequency in [100.0, 1000, rate*0.45] {
                for q in [0.2, 0.707, 4, 20] {
                    let bell = EQBand(frequency: frequency, q: q, gainDB: 6, version: 2)
                    let f = try XCTUnwrap(ParametricDSP.filter(bell, rate: rate))
                    XCTAssertEqual(f.responseDB(frequency, rate: rate), 6, accuracy: 0.0001)
                    XCTAssertTrue(f.c.allSatisfy(\.isFinite))
                }
            }
            for type in [EQFilterType.lowShelf, .highShelf] {
                let filter = try XCTUnwrap(ParametricDSP.filter(EQBand(frequency: 1000, q: 0.707, gainDB: 6, type: type, version: 2), rate: rate))
                XCTAssertEqual(filter.responseDB(type == .lowShelf ? 0 : rate/2, rate: rate), 6, accuracy: 0.001)
                XCTAssertEqual(filter.responseDB(type == .lowShelf ? rate/2 : 0, rate: rate), 0, accuracy: 0.001)
            }
            for type in [EQFilterType.highPass, .lowPass] {
                let filter = try XCTUnwrap(ParametricDSP.filter(EQBand(frequency: 1000, q: 1/sqrt(2), gainDB: 0, type: type, version: 2), rate: rate))
                XCTAssertEqual(filter.responseDB(1000, rate: rate), -3.0103, accuracy: 0.001)
            }
        }
    }
    func testCombinedResponseAndRecommendedPreampAreNotAppliedTwice() {
        let bands = [EQBand(frequency: 1000, q: 10, gainDB: 6, version: 2), EQBand(frequency: 1000, q: 10, gainDB: 6, version: 2)]
        XCTAssertEqual(ParametricDSP.headroom(bands: bands, rate: 48000), -13, accuracy: 0.001)
        XCTAssertEqual(ParametricDSP.headroom(bands: bands, rate: 48000, recommendedPreamp: -18), -18, accuracy: 0.001)
        XCTAssertEqual(ParametricDSP.headroom(bands: bands, rate: 48000, recommendedPreamp: -18, positiveGainDB: 8), -21, accuracy: 0.001)
    }
    func testImportUnderstandsUnitsBypassAndRejectsMalformedOrTooManyFilters() throws {
        let text = "Preamp: -6.2 dB\nFilter 1: ON PK Fc 1000 Hz Gain +3.0 dB Q 1.2\nFilter 2: OFF LS Fc 90 Hz Gain -2 dB Q 0.707"
        let profile = try CorrectionImport.parse(Data(text.utf8), name: "Owner headphones", kind: .headphones)
        XCTAssertEqual(profile.preampDB, -6.2)
        XCTAssertEqual(profile.bands.count, 2)
        XCTAssertFalse(profile.bands[1].enabled)
        XCTAssertEqual(profile.bands[1].type, .lowShelf)
        for bad in [text+"\nLimiter: ON", text.replacingOccurrences(of: "1.2", with: "NaN"), "Preamp: +12 dB", String(repeating: "x", count: 65537)] {
            XCTAssertThrowsError(try CorrectionImport.parse(Data(bad.utf8), name: "Bad", kind: .headphones))
        }
        let excessive = (1...11).map { "Filter \($0): ON PK Fc 1000 Hz Gain 0 dB Q 1" }.joined(separator: "\n")
        XCTAssertThrowsError(try CorrectionImport.parse(Data(excessive.utf8), name: "Too many", kind: .headphones))
        XCTAssertEqual(try CorrectionImport.parse(JSONEncoder().encode(profile), name: "Native", kind: .headphones), profile)
    }
    func testReferenceBypassIsUnityAndUnavailableFiltersAreExplicit() throws {
        var settings = DSPSettings(); settings.referenceBypass = true; settings.trimDB = -12
        let bands = [EQBand(frequency: 24000, q: 1, gainDB: 12, version: 2)]
        let bypass = ParametricDSP.parameters(user: bands, enabled: true, settings: settings, rate: 44100, replayGain: 4)
        XCTAssertEqual(bypass.preamp, 0)
        settings.referenceBypass = false
        XCTAssertEqual(ParametricDSP.parameters(user: bands, enabled: true, settings: settings, rate: 44100, replayGain: 1).unavailable, 1)
    }
}
