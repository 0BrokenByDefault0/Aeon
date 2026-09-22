import XCTest
@testable import App

final class CorrectionCatalogTests: XCTestCase {
    func testBundledModelsValidateAndKeepExactIdentity() throws {
        let records = try CorrectionCatalog.loaded.get()
        XCTAssertEqual(records.count, 9)
        XCTAssertEqual(Set(records.map(\.id)).count, records.count)
        XCTAssertEqual(records.filter { $0.matches("sony xm5") }.map(\.model), ["WH-1000XM5"])
        XCTAssertTrue(records.filter { $0.matches("AirPods Max") }.isEmpty)
        for entry in records {
            try CorrectionImport.validate(entry.profile)
            XCTAssertEqual(entry.creator, "oratory1990")
            XCTAssertEqual(entry.sourceRevision, "0b88ecd4e2bef7cf69fd5d50f1d06fb586c10865")
            XCTAssertEqual(entry.license, "CC BY-SA 4.0")
            XCTAssertEqual(try CorrectionImport.parse(JSONEncoder().encode(entry.profile), name: "Import", kind: .headphones), entry.profile)
        }
    }

    func testProfilesHaveFiniteBoundedCombinedResponseAndReferenceBypass() throws {
        for entry in try CorrectionCatalog.loaded.get() {
            for rate in [44_100.0, 48_000, 96_000] {
                var state = DSPSettings()
                state.profiles = [entry.profile]
                state.correctionID = entry.id
                state.correctionEnabled = true
                let user = [EQBand(frequency: 1000, q: 0.7, gainDB: 3, version: 2)]
                let tuned = ParametricDSP.parameters(user: user, enabled: true, settings: state, rate: rate, replayGain: 1)
                XCTAssertEqual(tuned.unavailable, 0)
                XCTAssertTrue(tuned.preamp.isFinite)
                XCTAssertLessThanOrEqual(tuned.preamp, entry.profile.preampDB)
                state.referenceBypass = true
                XCTAssertEqual(ParametricDSP.parameters(user: user, enabled: true, settings: state, rate: rate, replayGain: 1).preamp, 0)
                XCTAssertEqual(state.correction, entry.profile, "Bypass must preserve the profile")
            }
        }
    }
}
