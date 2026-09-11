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

    guard let selectedGain else { return 0 }
    return selectedGain + preampDB
}

func replayGainScalar(mode: ReplayGainMode, values: ReplayGainValues, preampDB: Double) -> Float {
    Float(pow(10.0, replayGainDB(mode: mode, values: values, preampDB: preampDB) / 20.0))
}
