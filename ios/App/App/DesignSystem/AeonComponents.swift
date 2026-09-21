import Dispatch
import Foundation
import SwiftUI
import UIKit

/// One cold-line language for controls and the hand-drawn navigation glyphs.
enum AeonOrbit {
    static let stroke: CGFloat = 1
    static let line = StrokeStyle(lineWidth: stroke, lineCap: .butt, lineJoin: .miter)
    static let title = AeonTheme.ColorToken.primary
    static let ink = AeonTheme.ColorToken.primary
    static let secondary = AeonTheme.ColorToken.secondary
    /// A press is a wash inside the ticks, never a filled control at rest.
    static let activeFill = AeonTheme.ColorToken.primary.opacity(0.08)
    static let supportingFont = AeonTheme.FontToken.ui(.subheadline, weight: .regular)
}

/// Four viewfinder ticks; no enclosing shape, radius, or fill.
///
/// The ticks are inset from the box and run inward, so the mark needs a box wide
/// enough to hold four separated corners. Drawn into anything smaller the opposite
/// arms cross and the mark collapses into a smear, which is what happened when this
/// was overlaid directly onto a two-letter `Text`. Undersized boxes are grown about
/// their own centre, and arm length can never exceed a third of either span.
struct AeonReticleMark: Shape {
    static let minimumSize = CGSize(width: 44, height: 26)
    var pressed = false

    static func resolvedBox(in bounds: CGRect) -> CGRect {
        let width = max(bounds.width, minimumSize.width)
        let height = max(bounds.height, minimumSize.height)
        guard width != bounds.width || height != bounds.height else { return bounds }
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    func path(in bounds: CGRect) -> Path {
        let box = Self.resolvedBox(in: bounds)
        let insetX: CGFloat = 8, insetY: CGFloat = 6
        let left = box.minX + insetX, right = box.maxX - insetX
        let top = box.minY + insetY, bottom = box.maxY - insetY
        guard right > left, bottom > top else { return Path() }
        let length = max(4, min(pressed ? 15 : 12, (right - left) / 3, (bottom - top) / 3))
        var path = Path()
        path.move(to: CGPoint(x: left, y: top + length)); path.addLine(to: CGPoint(x: left, y: top)); path.addLine(to: CGPoint(x: left + length, y: top))
        path.move(to: CGPoint(x: right - length, y: top)); path.addLine(to: CGPoint(x: right, y: top)); path.addLine(to: CGPoint(x: right, y: top + length))
        path.move(to: CGPoint(x: left, y: bottom - length)); path.addLine(to: CGPoint(x: left, y: bottom)); path.addLine(to: CGPoint(x: left + length, y: bottom))
        path.move(to: CGPoint(x: right - length, y: bottom)); path.addLine(to: CGPoint(x: right, y: bottom)); path.addLine(to: CGPoint(x: right, y: bottom - length))
        return path
    }
}

/// The area the four ticks enclose. Used only for the press wash, so a pressed
/// control reads as armed without ever becoming a filled shape at rest.
struct AeonReticleField: Shape {
    func path(in bounds: CGRect) -> Path {
        Path(AeonReticleMark.resolvedBox(in: bounds).insetBy(dx: 8, dy: 6))
    }
}

/// Touch feedback for a control set that is otherwise entirely unfilled strokes.
///
/// The visual press delta is deliberately small, so the haptic carries most of the
/// confirmation. Generators are prepared lazily and shared; UIKit coalesces repeats.
/// Deliberately not `@MainActor`. Call sites include `ButtonStyle.makeBody`, which the
/// protocol does not isolate, so an actor-isolated surface here would not compile from
/// the very places that need it. `UIFeedbackGenerator` is main-thread-only, so the hop
/// happens inside instead — synchronously when already on main, to keep haptics aligned
/// with the touch that caused them.
enum AeonFeedback {
    private static let selection = UISelectionFeedbackGenerator()
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let notice = UINotificationFeedbackGenerator()

    static var isEnabled = !AeonTestOverrides.reduceMotion

    private static func onMain(_ body: @escaping () -> Void) {
        guard isEnabled else { return }
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    /// Moving between tabs, segments, sort orders — anything that changes a selection.
    static func selectionChanged() { onMain { selection.selectionChanged() } }

    /// A control was activated: a button press, a toggle flip.
    static func activated() { onMain { light.impactOccurred() } }

    /// Transport edges: play, pause, track change. Firmer than an ordinary press.
    static func transport() { onMain { rigid.impactOccurred() } }

    static func succeeded() { onMain { notice.notificationOccurred(.success) } }

    static func failed() { onMain { notice.notificationOccurred(.error) } }
}

enum AeonGlyphKind {
    case sky, library, playlists, settings, star, arrow, files, folder
    case disclosure, picker, export, add, refresh
    case play, pause, next, previous, search, close, more, erase, shuffle, repeatTrack
    case volumeLow, volumeHigh, grip, check, overview, locate
}

/// Always decorative. An interactive parent owns the accessibility element, its label
/// and its identifier; a glyph never carries them itself, because a stroked Shape is
/// not exposed as an image element the way a filled SF Symbol was.
struct AeonGlyph: View {
    let kind: AeonGlyphKind
    var body: some View {
        AeonGlyphPath(kind: kind).stroke(style: AeonOrbit.line)
            .frame(width: 24, height: 24)
            // A stroked shape hit-tests only the stroke itself, so a button whose label
            // is a glyph has an activation point sitting in the gap between lines. These
            // replaced filled SF Symbols, whose opaque bodies made the whole box hittable.
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}

private struct AeonGlyphPath: Shape {
    let kind: AeonGlyphKind
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width / 24, y: rect.minY + y * rect.height / 24)
        }
        func line(_ points: [(CGFloat, CGFloat)]) {
            guard let first = points.first else { return }
            path.move(to: point(first.0, first.1))
            for p in points.dropFirst() { path.addLine(to: point(p.0, p.1)) }
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
            path.addEllipse(in: CGRect(x: point(x-r, y-r).x, y: point(x-r, y-r).y,
                                      width: r*2*rect.width/24, height: r*2*rect.height/24))
        }
        switch kind {
        case .overview:
            circle(12,12,8); circle(12,12,2)
            line([(2,12),(5,12)]); line([(19,12),(22,12)])
            line([(12,2),(12,5)]); line([(12,19),(12,22)])
        case .locate:
            line([(4,10),(21,3),(14,21),(11,13),(4,10)])
        case .star:
            line([(12,2),(14.3,9.7),(22,12),(14.3,14.3),(12,22),(9.7,14.3),(2,12),(9.7,9.7),(12,2)])
        case .sky:
            line([(10,3),(12,9),(18,11),(12,13),(10,19),(8,13),(2,11),(8,9),(10,3)])
            circle(20,4,1.2); circle(20,20,1.5)
        case .library:
            circle(14,12,8); circle(14,12,2)
            path.move(to: point(6,4)); path.addCurve(to: point(6,20), control1: point(-1,7), control2: point(-1,17))
        case .playlists:
            line([(3,15),(9,5),(14,18),(21,9)])
            circle(3,15,1.5); circle(9,5,2); circle(14,18,1.3); circle(21,9,2.2)
        case .settings:
            line([(5,2),(5,7)]); line([(5,13),(5,22)]); circle(5,10,3)
            line([(19,2),(19,13)]); line([(19,19),(19,22)]); circle(19,16,3)
        case .arrow:
            path.move(to: point(2,18))
            path.addCurve(to: point(21,6), control1: point(11,20), control2: point(15,6))
            line([(13,5),(21,6),(20,14)])
        case .disclosure:
            line([(9,5),(16,12),(9,19)])
        case .picker:
            line([(12,3),(12,15)]); line([(8,11),(12,15),(16,11)])
            line([(3,15),(3,21),(21,21),(21,15)])
        case .export:
            line([(12,16),(12,3)]); line([(8,7),(12,3),(16,7)])
            line([(3,15),(3,21),(21,21),(21,15)])
        case .add:
            line([(12,4),(12,20)]); line([(4,12),(20,12)])
        case .refresh:
            path.move(to: point(20,9))
            path.addCurve(to: point(5,6), control1: point(17,-1), control2: point(7,0))
            path.addCurve(to: point(18,20), control1: point(-3,18), control2: point(9,27))
            line([(15,9),(20,9),(21,4)])
        case .files:
            line([(5,3),(15,3),(20,8),(20,21),(5,21),(5,3),(15,3),(15,8),(20,8)])
            line([(8,15),(10,12),(12,17),(14,11),(17,15)])
        case .folder:
            line([(2,7),(2,4),(9,4),(12,7),(22,7),(22,20),(2,20),(2,7),(22,7)])
        case .play:
            line([(7,3),(20,12),(7,21),(7,3)])
        case .pause:
            line([(8,4),(8,20)]); line([(16,4),(16,20)])
        case .next:
            line([(5,4),(16,12),(5,20),(5,4)]); line([(19,4),(19,20)])
        case .previous:
            line([(19,4),(8,12),(19,20),(19,4)]); line([(5,4),(5,20)])
        case .search:
            circle(10,10,7)
            line([(15,15),(21,21)])
        case .close:
            line([(5,5),(19,19)]); line([(19,5),(5,19)])
        case .more:
            circle(5,12,1.3); circle(12,12,1.3); circle(19,12,1.3)
        case .erase:
            line([(4,6),(20,6)])
            line([(9,6),(9,3),(15,3),(15,6)])
            line([(6,6),(7,21),(17,21),(18,6)])
        case .shuffle:
            line([(3,6),(8,6),(16,18),(21,18)])
            line([(18,15),(21,18),(18,21)])
            line([(3,18),(8,18),(11,14)])
            line([(14,8),(16,6),(21,6)]); line([(18,3),(21,6),(18,9)])
        case .repeatTrack:
            line([(6,4),(18,4),(21,8),(18,12)])
            line([(18,20),(6,20),(3,16),(6,12)])
        case .volumeLow:
            line([(3,9),(7,9),(12,4),(12,20),(7,15),(3,15),(3,9)])
        case .volumeHigh:
            line([(2,9),(6,9),(11,4),(11,20),(6,15),(2,15),(2,9)])
            path.move(to: point(15,8)); path.addCurve(to: point(15,16), control1: point(18,10), control2: point(18,14))
            path.move(to: point(18,5)); path.addCurve(to: point(18,19), control1: point(23,9), control2: point(23,15))
        case .grip:
            line([(4,8),(20,8)]); line([(4,12),(20,12)]); line([(4,16),(20,16)])
        case .check:
            line([(4,12),(10,18),(20,6)])
        }
        return path
    }
}

struct AeonScreen<Content: View>: View {
    let playerVisible: Bool
    let content: (AeonReadableInsets) -> Content
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    init(playerVisible: Bool = false, @ViewBuilder content: @escaping (AeonReadableInsets) -> Content) {
        self.playerVisible = playerVisible; self.content = content
    }
    var body: some View {
        GeometryReader { geometry in
            let compact = horizontalSizeClass == .compact
            let readable = AeonReadableInsets(
                top: geometry.safeAreaInsets.top,
                leading: geometry.safeAreaInsets.leading + (compact ? 0 : AeonTheme.Space.sidebar),
                bottom: geometry.safeAreaInsets.bottom + (compact ? AeonTheme.Space.compactDock : 0)
                    + (compact && playerVisible ? AeonTheme.Space.playerBar : 0),
                trailing: geometry.safeAreaInsets.trailing
            )
            ZStack {
                AeonTheme.ColorToken.void.ignoresSafeArea()
                content(readable).environment(\.aeonReadableInsets, readable)
            }
        }
    }
}

struct AeonGlass<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        let opaque = reduceTransparency || AeonTestOverrides.reduceTransparency
        let increased = contrast == .increased || AeonTestOverrides.increasedContrast
        content
            // Utility surfaces do not blur the bright stars into muddy radial blobs.
            .background(AeonTheme.ColorToken.void.opacity(opaque ? 1 : 0.97))
            .overlay(Rectangle().stroke(increased ? AeonTheme.ColorToken.strongRule : AeonTheme.ColorToken.rule,
                                        lineWidth: AeonTheme.Stroke.hairline))
    }
}

struct AeonBreadcrumb: View {
    let text: String
    var body: some View {
        HStack(spacing: AeonTheme.Space.medium) {
            Text(text.uppercased()).fixedSize(horizontal: false, vertical: true)
            Rectangle().frame(height: AeonOrbit.stroke).opacity(0.35).accessibilityHidden(true)
        }
        .font(AeonTheme.FontToken.metric(.caption2, weight: .medium))
        .tracking(1.8).foregroundStyle(AeonOrbit.secondary)
        .frame(minHeight: AeonTheme.Space.minimumTarget)
    }
}

enum AeonButtonTier { case filled, hairline, bare }

struct AeonButtonStyle: ButtonStyle {
    let tier: AeonButtonTier
    var destructive = false
    /// Marks flanking a primary action. The house pair is the star and the swash arrow,
    /// which suit a call to action like IMPORT MUSIC. A transport action overrides them:
    /// a sparkle and a "go" arrow around the word PLAY say nothing about playing.
    var leadingMark: AeonGlyphKind = .star
    var trailingMark: AeonGlyphKind = .arrow
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            if tier == .filled { AeonGlyph(kind: leadingMark).frame(width: 42) }
            configuration.label
                .font(AeonTheme.FontToken.metric(.caption, weight: .semibold))
                .tracking(1.2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            if tier == .filled { AeonGlyph(kind: trailingMark).frame(width: 42) }
        }
        .padding(.horizontal, tier == .filled ? 4 : AeonTheme.Space.regular)
        .padding(.vertical, AeonTheme.Space.medium)
        .frame(minWidth: AeonTheme.Space.minimumTarget, maxWidth: .infinity,
               minHeight: tier == .filled ? 56 : AeonTheme.Space.minimumTarget)
        .foregroundStyle(destructive ? AeonTheme.ColorToken.danger : AeonOrbit.ink)
        .contentShape(Rectangle())
        .background {
            // Pressed controls fill only the area the ticks enclose; at rest nothing is filled.
            if tier != .bare, configuration.isPressed {
                AeonReticleField().fill(AeonOrbit.activeFill)
            }
        }
        .overlay {
            if tier != .bare {
                AeonReticleMark(pressed: configuration.isPressed)
                    .stroke(destructive ? AeonTheme.ColorToken.danger : AeonOrbit.ink.opacity(tier == .filled ? 1 : 0.48), style: AeonOrbit.line)
            }
        }
        .opacity(isEnabled ? 1 : 0.42)
        .animation(reduceMotion ? nil : .easeOut(duration: AeonTheme.Duration.press), value: configuration.isPressed)
        .onChange(of: configuration.isPressed) { pressed in
            guard pressed, isEnabled else { return }
            AeonFeedback.activated()
        }
    }
}

struct AeonToggleStyle: ToggleStyle {
    var showsLabel = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        Button {
            AeonFeedback.activated()
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: AeonTheme.Space.regular) {
                if showsLabel {
                    configuration.label
                    Spacer(minLength: AeonTheme.Space.small)
                }
                // Two equal cells, so the reticle always marks a full-size box rather than
                // two letterforms, and the control's trailing edge lines up with every
                // other row value on the screen.
                HStack(spacing: 0) {
                    Text("OFF")
                        .foregroundStyle(configuration.isOn ? AeonOrbit.secondary : AeonOrbit.ink)
                        .frame(width: 56, height: 44)
                        .background(!configuration.isOn ? AeonOrbit.activeFill : .clear)
                        .overlay { if !configuration.isOn { AeonReticleMark().stroke(AeonOrbit.ink, style: AeonOrbit.line) } }
                    Text("ON")
                        .foregroundStyle(configuration.isOn ? AeonOrbit.ink : AeonOrbit.secondary)
                        .frame(width: 56, height: 44)
                        .background(configuration.isOn ? AeonOrbit.activeFill : .clear)
                        .overlay { if configuration.isOn { AeonReticleMark().stroke(AeonOrbit.ink, style: AeonOrbit.line) } }
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 112, height: 44)
                .frame(minHeight: AeonTheme.Space.minimumTarget)
            }
            // The visible label, empty space, and control share one activation target.
            // XCTest and assistive technologies address the full represented switch row.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeInOut(duration: AeonTheme.Duration.chrome), value: configuration.isOn)
        .opacity(isEnabled ? 1 : 0.42)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

struct AeonSegment<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var identifier: (Value) -> String = { _ in "" }
    var spokenLabel: ((Value) -> String)? = nil
    @ScaledMetric(relativeTo: .caption2) private var metricSize: CGFloat = 11
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(values: [Value], selection: Binding<Value>, label: @escaping (Value) -> String,
         identifier: @escaping (Value) -> String = { _ in "" }, spokenLabel: ((Value) -> String)? = nil) {
        self.values = values; _selection = selection; self.label = label
        self.identifier = identifier; self.spokenLabel = spokenLabel
    }
    var body: some View {
        GeometryReader { geometry in
            let cellWidth = geometry.size.width / CGFloat(max(1, values.count))
            HStack(spacing: 0) {
                ForEach(values, id: \.self) { value in
                    Button {
                        if selection != value { AeonFeedback.selectionChanged() }
                        selection = value
                    } label: {
                        Text(label(value).uppercased())
                            .font(.system(size: min(metricSize, 17), weight: .medium, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(selection == value ? AeonOrbit.ink : AeonOrbit.secondary)
                            .frame(width: cellWidth, height: 48)
                            .background(selection == value ? AeonOrbit.activeFill : .clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(spokenLabel?(value) ?? label(value))
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
                    .accessibilityIdentifier(identifier(value))
                }
            }
            .overlay {
                if let index = values.firstIndex(of: selection) {
                    // The mark travels to the chosen cell instead of cutting, so the
                    // control reads as one instrument rather than five separate lamps.
                    AeonReticleMark().stroke(AeonOrbit.ink, style: AeonOrbit.line)
                        .frame(width: cellWidth, height: 48)
                        .offset(x: -geometry.size.width / 2 + cellWidth * (CGFloat(index) + 0.5))
                        .animation(reduceMotion || AeonTestOverrides.reduceMotion
                            ? nil : .easeOut(duration: AeonTheme.Duration.chrome), value: index)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 48)
        .accessibilityElement(children: .contain)
    }
}

struct AeonRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let trailing: Trailing
    init(title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.detail = detail; self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: AeonTheme.Space.medium) {
            VStack(alignment: .leading, spacing: AeonTheme.Space.xSmall) {
                Text(title).font(AeonTheme.FontToken.ui(.callout, weight: .medium)).foregroundStyle(AeonTheme.ColorToken.textPrimary)
                if let detail, !detail.isEmpty {
                    Text(detail).font(AeonTheme.FontToken.ui(.caption)).foregroundStyle(AeonOrbit.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AeonTheme.Space.small)
            trailing
        }
        .padding(.vertical, AeonTheme.Space.small).frame(minHeight: 62)
        .overlay(alignment: .bottom) { Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline) }
    }
}

extension AeonRow where Trailing == EmptyView {
    init(title: String, detail: String? = nil) { self.init(title: title, detail: detail) { EmptyView() } }
}

struct AeonLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(AeonTheme.FontToken.metric(.caption2, weight: .medium))
            .tracking(1.5).foregroundStyle(AeonOrbit.secondary)
    }
}

struct AeonArtwork: View {
    let image: Image?
    let size: CGFloat
    init(image: Image? = nil, size: CGFloat) { self.image = image; self.size = size }
    var body: some View {
        ZStack {
            AeonTheme.ColorToken.chamber
            if let image { image.resizable().scaledToFill() }
            else { AeonGhostDisc().padding(size * 0.13) }
        }
        .frame(width: size, height: size).clipped()
        .overlay(Rectangle().stroke(AeonOrbit.ink.opacity(0.28), style: AeonOrbit.line))
    }
}

struct AeonSheet<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AeonTheme.ColorToken.boneSecondary.opacity(0.74))
                .frame(width: 34, height: AeonOrbit.stroke).padding(.vertical, AeonTheme.Space.medium)
            content
        }
        .frame(maxWidth: AeonTheme.Space.textContentMaximum)
        .background(AeonTheme.ColorToken.void)
        .presentationDragIndicator(.hidden)
    }
}

struct AeonGhostDisc: View {
    var body: some View {
        ZStack {
            Circle().stroke(AeonOrbit.ink.opacity(0.18), style: AeonOrbit.line)
            Circle().stroke(AeonOrbit.ink.opacity(0.08), style: AeonOrbit.line).padding(8)
            Circle().stroke(AeonOrbit.ink.opacity(0.25), style: AeonOrbit.line).scaleEffect(0.09)
            Circle().fill(AeonOrbit.ink.opacity(0.025)).padding(1)
        }
        .aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }
}

struct AeonCollectionMark: View {
    var body: some View {
        ZStack {
            AeonGhostDisc().offset(x: -18, y: 5).opacity(0.4)
            AeonGhostDisc().offset(x: 14, y: -5)
        }
        .frame(width: 78, height: 78).padding(.horizontal, 20).accessibilityHidden(true)
    }
}

enum AeonEmptyMotif { case sky, collection, route }

/// One empty-state recipe: motif, serif headline, quiet copy, and a reachable action.
struct AeonEmptyState: View {
    let title: String
    let detail: String?
    let actionTitle: String?
    let motif: AeonEmptyMotif
    let actionIdentifier: String
    let action: (() -> Void)?

    init(title: String, detail: String?, actionTitle: String?, motif: AeonEmptyMotif = .route,
         actionIdentifier: String = "", action: (() -> Void)?) {
        self.title = title; self.detail = detail; self.actionTitle = actionTitle
        self.motif = motif; self.actionIdentifier = actionIdentifier; self.action = action
    }

    var body: some View {
        VStack(spacing: AeonTheme.Space.large) {
            Group {
                switch motif {
                case .sky: AeonGhostDisc().frame(width: 120, height: 120)
                case .collection: AeonCollectionMark()
                case .route: AeonRouteMark(width: 86, height: 62)
                }
            }
            .frame(height: 120)
            VStack(spacing: AeonTheme.Space.regular) {
                AeonDisplayText(title, size: 32).multilineTextAlignment(.center)
                if let detail {
                    Text(detail).font(AeonOrbit.supportingFont)
                        .foregroundStyle(AeonOrbit.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320)
                }
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(AeonButtonStyle(tier: .filled))
                    .frame(maxWidth: 300)
                    .accessibilityIdentifier(actionIdentifier)
            }
        }
        .foregroundStyle(AeonOrbit.title)
        .frame(maxWidth: 360).frame(maxWidth: .infinity)
        .padding(.vertical, AeonTheme.Space.large)
    }
}

struct AeonRouteMark: View {
    var width: CGFloat = 68
    var height: CGFloat = 48
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2, paused: reduceMotion || AeonTestOverrides.reduceMotion || scenePhase != .active)) { timeline in
            Canvas { context, size in
                let points = [CGPoint(x: size.width * 0.09, y: size.height * 0.46),
                              CGPoint(x: size.width * 0.34, y: size.height * 0.14),
                              CGPoint(x: size.width * 0.58, y: size.height * 0.86),
                              CGPoint(x: size.width * 0.9, y: size.height * 0.36)]
                var path = Path(); path.move(to: points[0]); points.dropFirst().forEach { path.addLine(to: $0) }
                context.stroke(path, with: .color(AeonOrbit.ink.opacity(0.22)), style: AeonOrbit.line)
                for (index, point) in points.enumerated() {
                    let radius: CGFloat = [1.5, 3, 1.8, 2.4][index]
                    let twinkle = reduceMotion || AeonTestOverrides.reduceMotion ? 0.85 : 0.8 + sin(timeline.date.timeIntervalSinceReferenceDate * 0.7) * 0.12
                    let opacity = index == 1 ? twinkle : [0.4, 0.85, 0.55, 0.7][index]
                    context.fill(Path(ellipseIn: CGRect(x: point.x-radius, y: point.y-radius, width: radius*2, height: radius*2)),
                                 with: .color(AeonOrbit.ink.opacity(opacity)))
                }
            }
        }
        .frame(width: width, height: height).accessibilityHidden(true)
    }
}

struct AeonImportSheet: View {
    let selectFiles: () -> Void
    let adoptLibrary: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var contentHeight: CGFloat = 340
    var body: some View {
        AeonSheet {
            ScrollView {
                VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                    VStack(alignment: .leading, spacing: AeonTheme.Space.regular) {
                        HStack(alignment: .top, spacing: AeonTheme.Space.small) {
                            AeonDisplayText("Choose a source", size: 32, maximumLines: 2)
                                .foregroundStyle(AeonOrbit.title)
                            Spacer(minLength: 0)
                            Button { dismiss() } label: {
                                AeonGlyph(kind: .close).frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).foregroundStyle(AeonOrbit.secondary)
                            .accessibilityLabel("Close import").accessibilityIdentifier("aeon.import.close")
                        }
                        Text("Import files, or scan the Music folder Aeon owns in Files.")
                            .font(AeonOrbit.supportingFont).foregroundStyle(AeonOrbit.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: AeonTheme.Space.medium) {
                        importOption(title: "Files", detail: "Choose one or more supported audio files.", glyph: .files,
                                     identifier: "aeon.library.import.files", action: selectFiles)
                        importOption(
                            title: "Adopt Library",
                            detail: "Scan On My iPhone → ISOLATION → Music. Album folders stay exactly where you put them.",
                            glyph: .folder,
                            identifier: "aeon.library.import.adopt",
                            action: adoptLibrary
                        )
                    }
                    Text("Each folder containing audio becomes one album when tags do not provide a better title. Re-scan anytime; existing albums are skipped and moved adopted albums are re-linked when the match is unambiguous.")
                        .font(AeonTheme.FontToken.ui(.caption))
                        .foregroundStyle(AeonOrbit.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("aeon.import.adopt.help")
                }
                .padding(.horizontal, AeonTheme.Space.edge)
                .padding(.top, AeonTheme.Space.small).padding(.bottom, AeonTheme.Space.large)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: AeonImportContentHeight.self, value: geometry.size.height)
                })
            }
            .scrollIndicators(.hidden)
        }
        .onPreferenceChange(AeonImportContentHeight.self) { measured in
            if measured > 0, abs(contentHeight - measured) > 1 { contentHeight = measured }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText
            ? [.large]
            : [.height(contentHeight + AeonTheme.Space.medium * 2 + AeonOrbit.stroke), .large])
        .accessibilityElement(children: .contain).accessibilityIdentifier("aeon.import.sheet")
    }
    private func importOption(title: String, detail: String, glyph: AeonGlyphKind,
                              identifier: String, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + AeonTheme.Duration.chrome) { action() }
        } label: {
            HStack(alignment: .top, spacing: AeonTheme.Space.regular) {
                AeonGlyph(kind: glyph).foregroundStyle(AeonOrbit.ink.opacity(0.78)).frame(width: 28)
                VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                    Text(title).font(AeonTheme.FontToken.ui(.callout, weight: .regular)).foregroundStyle(AeonTheme.ColorToken.textPrimary)
                    Text(detail).font(AeonTheme.FontToken.ui(.caption)).foregroundStyle(AeonOrbit.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AeonTheme.Space.small)
                AeonGlyph(kind: .picker).foregroundStyle(AeonOrbit.ink.opacity(0.6))
            }
            .padding(AeonTheme.Space.regular).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .contentShape(Rectangle())
            // A source card is a region to choose, not a chosen one. Corner ticks read as
            // selection, so cards keep a continuous unfilled outline.
            .overlay(RoundedRectangle(cornerRadius: AeonTheme.Radius.control, style: .continuous)
                .stroke(AeonOrbit.ink.opacity(0.34), style: AeonOrbit.line))
        }
        .buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
}

private struct AeonImportContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// A transient status line.
///
/// This sits on top of body copy, so it is fully opaque rather than `AeonGlass`'s 97%:
/// the three percent of bleed was enough to read the paragraph underneath through it.
struct AeonToast: View {
    let message: String
    var body: some View {
        Text(message)
            .font(AeonTheme.FontToken.ui(.callout, weight: .regular))
            .foregroundStyle(AeonOrbit.ink)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, AeonTheme.Space.large)
            .padding(.vertical, AeonTheme.Space.small)
            .frame(minHeight: AeonTheme.Space.minimumTarget)
            .background(AeonTheme.ColorToken.void)
            .overlay(Rectangle().stroke(AeonTheme.ColorToken.strongRule, lineWidth: AeonTheme.Stroke.hairline))
            .accessibilityAddTraits(.updatesFrequently)
            .transition(.opacity)
    }
}

struct AeonProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(AeonTheme.ColorToken.rule)
                Rectangle().fill(AeonOrbit.ink).frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 2).accessibilityValue("\(Int(min(1, max(0, value)) * 100)) percent")
    }
}
