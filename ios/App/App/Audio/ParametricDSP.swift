import Foundation

struct CorrectionProfile: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case headphones, speakerMeasurement, speakerTonal }
    var id: String = UUID().uuidString
    var version = 1
    var name: String
    var kind: Kind
    var preampDB: Double
    var bands: [EQBand]
    var provenance: String
}

struct TonalPreset: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var version = 2
    var name: String
    var detail: String
    var bands: [EQBand]
    var headroomPolicy = "Combined response + 1 dB margin"
    static let frequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static var flat: [EQBand] { frequencies.enumerated().map { EQBand(frequency: $0.element, q: 0.707, gainDB: 0, id: "user-\($0.offset)", version: 2) } }
    static let factory: [TonalPreset] = {
        func preset(_ name: String, _ detail: String, _ type: EQFilterType, _ frequency: Double, _ gain: Double, _ q: Double) -> TonalPreset {
            var bands = flat
            bands[0] = EQBand(frequency: frequency, q: q, gainDB: gain, id: "user-0", type: type, version: 2)
            return TonalPreset(id: name, name: name, detail: detail, bands: bands)
        }
        return [TonalPreset(id: "Flat", name: "Flat", detail: "Unity user bank; device correction remains separate.", bands: flat),
            preset("Bass lift", "Broad 90 Hz shelf, +2 dB.", .lowShelf, 90, 2, 0.707),
            preset("Bass reduction", "Broad 100 Hz shelf, −2 dB.", .lowShelf, 100, -2, 0.707),
            preset("Less low-mid", "250 Hz bell, −2 dB, Q 0.8.", .bell, 250, -2, 0.8),
            preset("Gentle presence", "2 kHz bell, +1.5 dB, Q 0.7.", .bell, 2000, 1.5, 0.7),
            preset("Softer treble", "4.5 kHz shelf, −2 dB.", .highShelf, 4500, -2, 0.707)]
    }()
}

struct DSPSettings: Codable, Equatable {
    var version = 1
    var correctionEnabled = false
    var correctionID: String?
    var profiles: [CorrectionProfile] = []
    var savedPresets: [TonalPreset] = []
    var presetID: String?
    var trimDB: Double = 0
    var referenceBypass = false
    var routeBindings: [String: String] = [:]
    // A route change clears correction. No model inference from generic route names.
    var correction: CorrectionProfile? { profiles.first { $0.id == correctionID } }
    var activeCorrection: CorrectionProfile? { correctionEnabled && !referenceBypass ? correction : nil }
}

enum DSPError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

struct Biquad {
    let c: [Double] // b0 b1 b2 a1 a2, normalized a0
    func responseDB(_ frequency: Double, rate: Double) -> Double {
        let w = 2 * Double.pi * frequency / rate
        let numerator = hypot(c[0] + c[1] * cos(w) + c[2] * cos(2*w), -c[1]*sin(w) - c[2]*sin(2*w))
        let denominator = hypot(1 + c[3] * cos(w) + c[4] * cos(2*w), -c[3]*sin(w) - c[4]*sin(2*w))
        return 20 * log10(max(1e-15, numerator) / max(1e-15, denominator))
    }
}

enum ParametricDSP {
    static func validate(_ bands: [EQBand], limit: Int = 10) throws {
        guard bands.count <= limit else { throw DSPError.invalid("This bank supports \(limit) filters; none were applied.") }
        for (i, b) in bands.enumerated() {
            guard b.frequency.isFinite, (20...24000).contains(b.frequency), b.q.isFinite, (0.1...20).contains(b.q),
                  b.gainDB.isFinite, (-96...24).contains(b.gainDB), (1...2).contains(b.version) else {
                throw DSPError.invalid("Filter \(i+1): use 20–24000 Hz, Q 0.1–20, and −96…+24 dB.")
            }
        }
    }
    // RBJ digital biquads. q is Q, including shelf resonance (not octave BW or slope S).
    // Legacy v1 uses the historical analog-Q -> native octave width conversion separately.
    static func filter(_ b: EQBand, rate: Double) -> Biquad? {
        guard b.enabled, b.frequency < rate * 0.499 else { return nil }
        let w = 2 * Double.pi * b.frequency / rate, co = cos(w), si = sin(w), a = pow(10, b.gainDB/40)
        let alpha = b.version == 1 ? si * sinh(asinh(1 / (2*b.q)) * w / si) : si / (2*b.q)
        let r = 2 * sqrt(a) * alpha
        var n: [Double], d: [Double]
        switch b.type {
        case .bell: n = [1+alpha*a, -2*co, 1-alpha*a]; d = [1+alpha/a, -2*co, 1-alpha/a]
        case .lowShelf:
            n = [a*((a+1)-(a-1)*co+r), 2*a*((a-1)-(a+1)*co), a*((a+1)-(a-1)*co-r)]
            d = [(a+1)+(a-1)*co+r, -2*((a-1)+(a+1)*co), (a+1)+(a-1)*co-r]
        case .highShelf:
            n = [a*((a+1)+(a-1)*co+r), -2*a*((a-1)+(a+1)*co), a*((a+1)+(a-1)*co-r)]
            d = [(a+1)-(a-1)*co+r, 2*((a-1)-(a+1)*co), (a+1)-(a-1)*co-r]
        case .highPass: n = [(1+co)/2, -(1+co), (1+co)/2]; d = [1+alpha, -2*co, 1-alpha]
        case .lowPass: n = [(1-co)/2, 1-co, (1-co)/2]; d = [1+alpha, -2*co, 1-alpha]
        }
        return Biquad(c: n.map { $0/d[0] } + [d[1]/d[0], d[2]/d[0]])
    }
    static func response(_ bands: [EQBand], frequency: Double, rate: Double) -> Double {
        bands.compactMap { filter($0, rate: rate) }.reduce(0) { $0 + $1.responseDB(frequency, rate: rate) }
    }
    static func headroom(bands: [EQBand], rate: Double, recommendedPreamp: Double = 0, positiveGainDB: Double = 0) -> Double {
        let filters = bands.compactMap { filter($0, rate: rate) }
        guard !filters.isEmpty || positiveGainDB > 0 || recommendedPreamp != 0 else { return 0 }
        var frequencies = (0...2048).map { 10 * pow(rate * 0.0499, Double($0)/2048) }
        frequencies += [0, rate * 0.499]
        // Refine around every center, including very narrow overlapping peaks.
        for b in bands where b.enabled { for step in -32...32 { frequencies.append(b.frequency * pow(2, Double(step) / (64 * b.q))) } }
        let peak = frequencies.filter { $0 >= 0 && $0 < rate/2 }.reduce(0.0) { result, f in
            max(result, filters.reduce(0) { $0 + $1.responseDB(f, rate: rate) })
        }
        // Recommended preamp is a floor on attenuation, not a second multiplier.
        let boost = max(0, peak + max(0, positiveGainDB))
        return min(0, recommendedPreamp, boost > 0.000001 ? -boost - 1 : 0)
    }
    static func parameters(user: [EQBand], enabled: Bool, settings: DSPSettings, rate: Double, replayGain: Double) -> (data: Data, preamp: Double, unavailable: Int) {
        let activeUser = enabled && !settings.referenceBypass ? user : []
        let correction = settings.activeCorrection
        let combined = (correction?.bands ?? []) + activeUser
        let programmable = (correction?.bands ?? []) + activeUser.filter { $0.version >= 2 }
        let filters = programmable.compactMap { filter($0, rate: rate) }
        let protect = !settings.referenceBypass
        let preamp = settings.referenceBypass ? 0 : headroom(bands: combined, rate: rate,
            recommendedPreamp: correction?.preampDB ?? 0, positiveGainDB: 20 * log10(max(1, replayGain)))
        let trim = settings.referenceBypass ? 0 : min(0, settings.trimDB)
        // Legacy native EQ has unity global gain; one shared attenuation owns both banks.
        var values = [Double(filters.count), pow(10, (preamp + trim)/20), protect ? 1.0 : 0.0]
        values += filters.flatMap(\.c)
        values += Array(repeating: 0, count: (20-filters.count)*5)
        return (values.withUnsafeBytes { Data($0) }, preamp,
                combined.filter { $0.enabled && $0.frequency >= rate * 0.499 }.count)
    }
}
