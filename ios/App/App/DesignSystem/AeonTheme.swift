import SwiftUI
import UIKit

enum AeonTheme {
    enum ColorToken {
        // Core editorial palette from the Aeon 5 product-design handoff.
        static let void = Color(red: 10 / 255, green: 10 / 255, blue: 11 / 255)
        static let chamber = Color(red: 21 / 255, green: 22 / 255, blue: 25 / 255)
        static let chamberOpaque = chamber.opacity(0.98)
        static let surfaceSelected = Color(red: 29 / 255, green: 31 / 255, blue: 35 / 255)

        static let bone = Color(red: 242 / 255, green: 236 / 255, blue: 217 / 255)
        static let ivorySecondary = Color(red: 216 / 255, green: 208 / 255, blue: 185 / 255)
        static let textPrimary = Color(red: 244 / 255, green: 242 / 255, blue: 236 / 255)
        static let boneSecondary = Color(red: 183 / 255, green: 184 / 255, blue: 188 / 255)
        static let boneTertiary = Color(red: 133 / 255, green: 135 / 255, blue: 141 / 255)

        // Retained as a compatibility alias for older surfaces; new selection states
        // should prefer surfaceSelected or ivorySecondary.
        static let silver = ivorySecondary
        static let rule = Color.white.opacity(0.16)
        static let strongRule = Color.white.opacity(0.30)
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

        static func ui(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
            .system(style, design: .default, weight: weight)
        }

        static func metric(_ style: Font.TextStyle = .caption, weight: Font.Weight = .regular) -> Font {
            .system(style, design: .monospaced, weight: weight).monospacedDigit()
        }
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
