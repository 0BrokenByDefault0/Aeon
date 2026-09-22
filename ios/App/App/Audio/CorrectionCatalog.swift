import Foundation

/// An attributed, pinned data record; choosing it never guesses the connected model.
struct BundledCorrection: Codable, Identifiable {
    let manufacturer: String
    let model: String
    let operatingMode: String
    let creator: String
    let measurementProvider: String
    let target: String
    let sourceRevision: String
    let snapshotDate: String
    let sourceURL: String
    let originalURL: String
    let license: String
    let profile: CorrectionProfile
    var id: String { profile.id }

    func matches(_ query: String) -> Bool {
        let text = "\(manufacturer) \(model) \(target) \(creator)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.localizedCaseInsensitiveContains(String($0))
        }
    }
}

enum CorrectionCatalog {
    private struct Contents: Decodable {
        let version: Int
        let profiles: [BundledCorrection]
    }

    static let loaded: Result<[BundledCorrection], Error> = Result {
        guard let url = Bundle.main.url(forResource: "profiles", withExtension: "json", subdirectory: "CorrectionCatalog") else {
            throw DSPError.invalid("The bundled headphone catalogue could not be opened. Imported profiles remain available.")
        }
        return try decode(Data(contentsOf: url))
    }

    static var profiles: [BundledCorrection] { (try? loaded.get()) ?? [] }

    static func decode(_ data: Data) throws -> [BundledCorrection] {
        let contents = try JSONDecoder().decode(Contents.self, from: data)
        guard contents.version == 1, !contents.profiles.isEmpty,
              Set(contents.profiles.map(\.id)).count == contents.profiles.count else {
            throw DSPError.invalid("Unsupported or duplicate headphone catalogue records.")
        }
        for entry in contents.profiles { try CorrectionImport.validate(entry.profile) }
        return contents.profiles
    }
}
