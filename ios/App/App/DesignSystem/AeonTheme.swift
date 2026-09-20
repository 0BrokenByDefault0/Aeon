import SwiftUI
import UIKit

enum AeonTheme {
    enum ColorToken {
        static let void = Color.black
        static let chamber = Color(red: 10 / 255, green: 13 / 255, blue: 18 / 255)
        static let chamberOpaque = chamber.opacity(0.98)
        static let surfaceSelected = Color(red: 20 / 255, green: 25 / 255, blue: 33 / 255)

        static let primary = Color(red: 232 / 255, green: 237 / 255, blue: 244 / 255)
        static let secondary = Color(red: 168 / 255, green: 178 / 255, blue: 193 / 255)
        static let tertiary = Color(red: 126 / 255, green: 136 / 255, blue: 152 / 255)
        static let hairline = Color(red: 42 / 255, green: 48 / 255, blue: 58 / 255)
        // Compatibility names keep the surface diff small; all resolve to the cold ramp.
        static let bone = primary
        static let ivorySecondary = secondary
        static let textPrimary = primary
        static let boneSecondary = secondary
        static let boneTertiary = tertiary
        static let silver = secondary
        static let rule = hairline
        static let strongRule = secondary.opacity(0.52)
        static let interactive = primary
        static let disabled = tertiary.opacity(0.55)
        static let separator = hairline
        static let surface = chamber
        static let danger = Color(red: 0.87, green: 0.36, blue: 0.31)
    }

    enum Space {
        static let hairline: CGFloat = 0.5
        static let compactEdge: CGFloat = 20
        static let edge: CGFloat = 24
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let regular: CGFloat = 16
        static let large: CGFloat = 24
        static let section: CGFloat = 40
        static let hero: CGFloat = 48
        static let minimumTarget: CGFloat = 44
        static let compactDock: CGFloat = 74
        static let playerBar: CGFloat = 72
        static let sidebar: CGFloat = 196
        static let sidePanel: CGFloat = 560
        static let textContentMaximum: CGFloat = 900
    }

    enum Radius {
        static let compact: CGFloat = 14
        static let control: CGFloat = 16
        static let surface: CGFloat = 18
    }

    enum Stroke {
        static let hairline: CGFloat = 0.5
        static let focus: CGFloat = 1
        static let artworkOffset: CGFloat = 3
    }

    enum Shadow {
        static let glassRadius: CGFloat = 18
        static let glassY: CGFloat = 10
        static let artworkRadius: CGFloat = 14
        static let artworkY: CGFloat = 8
    }

    enum Duration {
        static let immediate = 0.12
        static let press = 0.16
        static let chrome = 0.24
        static let sheet = 0.34
        static let constellationBreath = 5.2
        static let toast = 3.2
    }

    enum Layer {
        static let sky: Double = 0
        static let content: Double = 10
        static let chrome: Double = 20
        static let sheet: Double = 30
        static let toast: Double = 40
    }

    enum FontToken {
        static let nocturnePostScriptName = "AeonNocturne-Regular"
        static let maximumDisplayScale: CGFloat = 1.55

        /// Running text: titles people read, names, and paragraphs of prose.
        ///
        /// This was briefly monospaced along with everything else. Mono has no width
        /// variation to ration, so multi-line body copy — the metadata-lookup disclosure
        /// in Settings especially — wrapped raggedly and read as log output, and an
        /// artist name in mono under a serif album title fought the display face.
        /// Measurements keep the mono; prose does not.
        static func ui(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
            .system(style, design: .default, weight: weight)
        }

        /// Anything that is a value rather than a sentence: counts, timecodes, eyebrows,
        /// tracked labels. Tabular figures so digits do not jitter as they update.
        static func metric(_ style: Font.TextStyle = .caption, weight: Font.Weight = .regular) -> Font {
            .system(style, design: .monospaced, weight: weight).monospacedDigit()
        }

        // Semantic roles keep hierarchy consistent while preserving Dynamic Type.
        static let title = ui(.title2, weight: .semibold)
        static let body = ui(.body)
        static let secondary = ui(.subheadline)
        static let utility = ui(.callout, weight: .medium)
        static let metadata = metric(.caption)
        static let microLabel = metric(.caption2, weight: .medium)
    }
}

struct AeonDisplayText: View {
    let text: String
    let baseSize: CGFloat
    let maximumLines: Int
    @ScaledMetric(relativeTo: .largeTitle) private var scaledSize: CGFloat = 1

    init(_ text: String, size: CGFloat, maximumLines: Int = 3) {
        self.text = text
        baseSize = size
        self.maximumLines = maximumLines
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
    }

    var body: some View {
        Text(text)
            .font(.custom(
                AeonTheme.FontToken.nocturnePostScriptName,
                fixedSize: min(scaledSize, baseSize * AeonTheme.FontToken.maximumDisplayScale)
            ))
            .lineLimit(maximumLines)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AeonReadableInsets: Equatable {
    var top: CGFloat = 0
    var leading: CGFloat = 0
    var bottom: CGFloat = 0
    var trailing: CGFloat = 0
}

private struct AeonReadableInsetsKey: EnvironmentKey {
    static let defaultValue = AeonReadableInsets()
}

private struct AeonArtworkTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var aeonReadableInsets: AeonReadableInsets {
        get { self[AeonReadableInsetsKey.self] }
        set { self[AeonReadableInsetsKey.self] = newValue }
    }

    var aeonArtworkTint: Color? {
        get { self[AeonArtworkTintKey.self] }
        set { self[AeonArtworkTintKey.self] = newValue }
    }
}

enum AeonArtworkTint {
    static func resolve(
        trackID: String?,
        catalog: CatalogRepository,
        artworkStore: ArtworkStore
    ) -> UIColor? {
        guard let trackID,
              let track = try? catalog.track(id: trackID),
              let album = try? catalog.album(id: track.albumID),
              let key = album.artworkKey,
              let url = try? artworkStore.url(forKey: key),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return sample(image)
    }

    static func sample(_ image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let components = pixel.prefix(3).map { CGFloat($0) / 255 }
        let maximum = components.max() ?? 0
        guard maximum > 0.08 else { return nil }
        let restrained = components.map { min(0.72, max(0.16, $0 * 0.68 + 0.10)) }
        return UIColor(red: restrained[0], green: restrained[1], blue: restrained[2], alpha: 1)
    }
}
