import SwiftUI
import UIKit

/// Aeon's visual system.
///
/// Two rules decide everything here. The ground is true black, so the sky can
/// own the screen on an OLED panel and the instrument reads as glass laid over
/// it; and there is exactly one typeface, Archivo, set at two widths — expanded
/// for the names of things, normal for everything you operate.
enum AeonTheme {
    enum ColorToken {
        /// The ground. Literal black: on OLED the panel switches off here.
        static let void = Color.black
        /// The pane. Almost nothing — it reads as a pane because of its edge.
        static let chamber = Color(red: 0.043, green: 0.047, blue: 0.055)
        static let chamberOpaque = Color(red: 0.027, green: 0.030, blue: 0.036).opacity(0.96)
        /// Text is white at descending opacities, never a grey mixed from paper.
        static let bone = Color.white
        static let boneSecondary = Color.white.opacity(0.62)
        static let boneTertiary = Color.white.opacity(0.42)
        static let silver = Color.white.opacity(0.28)
        static let rule = Color.white.opacity(0.10)
        static let strongRule = Color.white.opacity(0.26)
        static let danger = Color(red: 0.89, green: 0.44, blue: 0.38)

        /// Names the 5.0 surfaces already use, re-pointed at the new palette so
        /// every screen moves with the skin rather than being rewritten.
        static let surfaceSelected = Color.white.opacity(0.09)
        static let ivorySecondary = boneSecondary
        static let textPrimary = bone

        /// The accent when nothing is playing — replaced by the artwork tint.
        static let restingTint = Color(red: 0.66, green: 0.78, blue: 1.0)

        /// The edge that makes glass read as a physical pane: bright where the
        /// light lands, gone by the middle, faintly caught again at the far side.
        static let edgeHighlight = Gradient(stops: [
            .init(color: .white.opacity(0.34), location: 0),
            .init(color: .white.opacity(0.10), location: 0.32),
            .init(color: .white.opacity(0.02), location: 0.62),
            .init(color: .white.opacity(0.11), location: 1)
        ])
    }

    enum Space {
        static let hairline: CGFloat = 0.5
        static let compactEdge: CGFloat = 18
        static let edge: CGFloat = 26
        static let tiny: CGFloat = 4
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let regular: CGFloat = 16
        static let large: CGFloat = 18
        static let section: CGFloat = 26
        static let vast: CGFloat = 40
        static let hero: CGFloat = 48
        static let minimumTarget: CGFloat = 44
        /// Glyph navigation carries no bar of its own — this is clearance, not chrome.
        static let compactDock: CGFloat = 58
        static let playerBar: CGFloat = 62
        static let sidebar: CGFloat = 196
        static let sidePanel: CGFloat = 560
        static let textContentMaximum: CGFloat = 900
    }

    /// Corners are soft and consistent; nothing in the instrument is square.
    enum Radius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 22
        static let sheet: CGFloat = 30
        static let pill: CGFloat = 999

        /// The 5.0 names, mapped onto the same scale.
        static let compact = small
        static let control = medium
        static let surface = large
    }

    enum Stroke {
        static let hairline: CGFloat = 0.5
        static let focus: CGFloat = 1
        static let artworkOffset: CGFloat = 3
    }

    enum Shadow {
        static let glassRadius: CGFloat = 22
        static let glassY: CGFloat = 12
        static let artworkRadius: CGFloat = 20
        static let artworkY: CGFloat = 12
    }

    enum Duration {
        static let immediate = 0.12
        static let press = 0.16
        static let chrome = 0.24
        static let constellationBreath = 5.2
        static let sheet = 0.34
        static let toast = 3.2
    }

    /// One family of curves, so nothing in the app moves in a way the rest of
    /// it does not. Sheets and panels carry weight; controls settle at once.
    enum Motion {
        static let control = Animation.easeOut(duration: Duration.immediate)
        static let chrome = Animation.easeInOut(duration: Duration.chrome)
        static let panel = Animation.spring(response: 0.42, dampingFraction: 0.88)
        static let sheet = Animation.spring(response: 0.48, dampingFraction: 0.86)
        /// Every camera move in the sky, distance-scaled by the caller.
        static let flight = Animation.timingCurve(0.22, 0.61, 0.16, 1, duration: 0.78)
    }

    enum Layer {
        static let sky: Double = 0
        static let content: Double = 10
        static let chrome: Double = 20
        static let sheet: Double = 30
        static let toast: Double = 40
    }

    /// Two faces, drawn from the same sharp, flat-terminal grotesque family.
    ///
    /// **Clash Display Semibold** says the names of things. It is cut rather
    /// than drawn: flat terminals, tight apertures, little roundness, which is
    /// what keeps a title dramatic instead of soft at 44pt on black.
    ///
    /// **Switzer** is everything you operate — rows, body copy, buttons,
    /// settings, counts. Same discipline at text sizes, where the display face
    /// would be too tightly spaced to read.
    ///
    /// Both are addressed by the PostScript names of static cuts. A `Font` made
    /// from a `UIFont` is a fixed size to SwiftUI and stops answering Dynamic
    /// Type; `Font.custom(_:size:relativeTo:)` scales.
    enum FontToken {
        static let displayName = "ClashDisplay-Semibold"
        static let textFamily = "Switzer"
        /// Kept: the Nocturne face still ships, with its licences, as provenance.
        static let nocturnePostScriptName = "AeonNocturne-Regular"
        static let maximumDisplayScale: CGFloat = 1.55

        /// Uppercase micro labels are the only tracked-out type in the app.
        static let labelTracking: CGFloat = 1.6

        /// Names of things: screen titles, album and playlist names, planets.
        /// `AeonDisplayText` scales the point size it passes in, so this one is
        /// deliberately not scaled again here.
        static func display(size: CGFloat) -> Font {
            .custom(displayName, fixedSize: size)
        }

        static func uiDisplay(size: CGFloat) -> UIFont {
            UIFont(name: displayName, size: size) ?? .systemFont(ofSize: size, weight: .semibold)
        }

        /// Rows, body copy, buttons, settings.
        static func ui(_ style: Font.TextStyle = .body, weight: Font.Weight = .regular) -> Font {
            .custom(cutName(for: weight), size: pointSize(for: style), relativeTo: style)
        }

        /// Counts, durations, coordinates — the same face, figures aligned.
        static func metric(_ style: Font.TextStyle = .caption, weight: Font.Weight = .medium) -> Font {
            ui(style, weight: weight).monospacedDigit()
        }

        /// The interface face as a `UIFont`, for the places UIKit needs one.
        static func uiText(size: CGFloat, weight: Font.Weight = .regular) -> UIFont {
            UIFont(name: cutName(for: weight), size: size)
                ?? .systemFont(ofSize: size, weight: .regular)
        }

        /// PostScript names of the bundled static cuts.
        static func cutName(for weight: Font.Weight) -> String {
            switch weight {
            case .medium: return "Switzer-Medium"
            case .semibold: return "Switzer-Semibold"
            case .bold, .heavy, .black: return "Switzer-Bold"
            default: return "Switzer-Regular"
            }
        }

        static func pointSize(for style: Font.TextStyle) -> CGFloat {
            switch style {
            case .largeTitle: return 34
            case .title: return 28
            case .title2: return 22
            case .title3: return 20
            case .headline, .body: return 15
            case .callout: return 14
            case .subheadline: return 13
            case .footnote: return 12
            case .caption: return 11
            case .caption2: return 10
            @unknown default: return 15
            }
        }
    }
}

/// A name of a thing, set expanded and large, capped so it cannot run off the
/// screen at accessibility sizes.
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
            .font(AeonTheme.FontToken.display(
                size: min(scaledSize, baseSize * AeonTheme.FontToken.maximumDisplayScale)
            ))
            .tracking(baseSize * -0.022)
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
