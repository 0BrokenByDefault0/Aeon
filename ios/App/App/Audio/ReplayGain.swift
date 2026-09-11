import Foundation

struct ReplayGainValues: Codable, Equatable {
    let trackGainDB: Double?
    let albumGainDB: Double?
    let trackPeak: Double?
    let albumPeak: Double?

    static let empty = ReplayGainValues(
        trackGainDB: nil,
        albumGainDB: nil,
        trackPeak: nil,
        albumPeak: nil
    )
}

func replayGainDB(mode: ReplayGainMode, values: ReplayGainValues, preampDB: Double) -> Double {
    let selectedGain: Double?
    switch mode {
    case .off:
        return 0
    case .album:
        selectedGain = values.albumGainDB
    case .track:
        selectedGain = values.trackGainDB
    }

    guard let selectedGain, selectedGain.isFinite, preampDB.isFinite else { return 0 }
    let combinedGain = selectedGain + preampDB
    return combinedGain.isFinite ? combinedGain : 0
}

func replayGainScalar(mode: ReplayGainMode, values: ReplayGainValues, preampDB: Double) -> Float {
    let db = replayGainDB(mode: mode, values: values, preampDB: preampDB)
    let scalar = Float(pow(10.0, db / 20.0))
    return scalar.isFinite && scalar > 0 ? scalar : 1
}
