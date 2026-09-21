import Foundation

// Equalizer APO / AutoEq parametric subset; 64 KiB, ten filters, explicit units.
// Parsing runs on the import worker, never in the renderer. Unknown constructs fail closed.
enum CorrectionImport {
    static func parse(_ data: Data, name: String, kind: CorrectionProfile.Kind) throws -> CorrectionProfile {
        guard data.count <= 65_536 else { throw DSPError.invalid("Profile exceeds the 64 KiB limit.") }
        if let first = data.first(where: { ![9,10,13,32].contains($0) }), first == 123 {
            let profile = try JSONDecoder().decode(CorrectionProfile.self, from: data)
            try validate(profile)
            return profile
        }
        guard let text = String(data: data, encoding: .utf8) else { throw DSPError.invalid("Use UTF-8 parametric text or an Aeon JSON profile.") }
        let number = #"([+-]?(?:\d+(?:\.\d*)?|\.\d+))"#
        let preamp = try NSRegularExpression(pattern: "^Preamp:\\s*" + number + "\\s*dB$", options: .caseInsensitive)
        let filter = try NSRegularExpression(pattern: "^Filter\\s+(\\d+):\\s+(ON|OFF)\\s+(PK|PEQ|LS|LSC|HS|HSC|HP|LP)\\s+Fc\\s+" + number + "\\s*Hz(?:\\s+Gain\\s+" + number + "\\s*dB)?\\s+Q\\s+" + number + "$", options: .caseInsensitive)
        var gain = 0.0, hasPreamp = false, bands: [EQBand] = [], ids = Set<String>()
        for (index, source) in text.components(separatedBy: .newlines).enumerated() {
            let line = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            let ns = line as NSString, range = NSRange(location: 0, length: ns.length)
            if let m = preamp.firstMatch(in: line, range: range) {
                guard !hasPreamp else { throw DSPError.invalid("Line \(index+1): duplicate preamp.") }
                gain = Double(ns.substring(with: m.range(at: 1))) ?? .nan; hasPreamp = true; continue
            }
            guard let m = filter.firstMatch(in: line, range: range) else {
                throw DSPError.invalid("Line \(index+1): expected Preamp in dB, or ON/OFF PK/LS/HS/HP/LP with Fc in Hz and Q. Unsupported syntax was not applied.")
            }
            func value(_ n: Int) -> String { m.range(at: n).location == NSNotFound ? "" : ns.substring(with: m.range(at: n)) }
            let id = value(1)
            guard ids.insert(id).inserted else { throw DSPError.invalid("Line \(index+1): duplicate filter number.") }
            let type: EQFilterType
            switch value(3).uppercased() {
            case "LS", "LSC": type = .lowShelf
            case "HS", "HSC": type = .highShelf
            case "HP": type = .highPass
            case "LP": type = .lowPass
            default: type = .bell
            }
            if [.bell, .lowShelf, .highShelf].contains(type) && value(5).isEmpty { throw DSPError.invalid("Line \(index+1): missing Gain in dB.") }
            if [.highPass, .lowPass].contains(type) && !value(5).isEmpty { throw DSPError.invalid("Line \(index+1): cut filters do not take a gain.") }
            bands.append(EQBand(frequency: Double(value(4)) ?? .nan, q: Double(value(6)) ?? .nan,
                gainDB: Double(value(5)) ?? 0, id: "import-" + id, enabled: value(2).uppercased() == "ON", type: type, version: 2))
        }
        let profile = CorrectionProfile(name: name, kind: kind, preampDB: gain, bands: bands,
            provenance: "Imported settings supplied by owner; measurement source and target not verified by Aeon.")
        try validate(profile)
        return profile
    }
    static func validate(_ profile: CorrectionProfile) throws {
        guard profile.version == 1, !profile.name.trimmingCharacters(in: .whitespaces).isEmpty, profile.name.count <= 160,
              profile.preampDB.isFinite, (-36...0).contains(profile.preampDB), !profile.bands.isEmpty,
              profile.bands.allSatisfy({ $0.version == 2 }) else {
            throw DSPError.invalid("Use a version 1 named profile, −36…0 dB preamp and version 2 filters.")
        }
        try ParametricDSP.validate(profile.bands)
    }
}
