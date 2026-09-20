import Dispatch
import SwiftUI
import UIKit

/// One cold-line language for controls and the hand-drawn navigation glyphs.
enum AeonOrbit {
    static let stroke: CGFloat = 1
    static let line = StrokeStyle(lineWidth: stroke, lineCap: .butt, lineJoin: .miter)
    static let title = AeonTheme.ColorToken.primary
    static let ink = AeonTheme.ColorToken.primary
    static let secondary = AeonTheme.ColorToken.secondary
    static let activeFill = Color.clear
    static let supportingFont = AeonTheme.FontToken.ui(.subheadline, weight: .regular)
}

/// Four viewfinder ticks; no enclosing shape, radius, or fill.
struct AeonReticleMark: Shape {
    var pressed = false
    func path(in bounds: CGRect) -> Path {
        let length = min(pressed ? 14 : 12, max(6, bounds.height * 0.22))
        let insetX: CGFloat = 8, insetY: CGFloat = 6
        let left = bounds.minX + insetX, right = bounds.maxX - insetX
        let top = bounds.minY + insetY, bottom = bounds.maxY - insetY
        var path = Path()
        path.move(to: CGPoint(x: left, y: top + length)); path.addLine(to: CGPoint(x: left, y: top)); path.addLine(to: CGPoint(x: left + length, y: top))
        path.move(to: CGPoint(x: right - length, y: top)); path.addLine(to: CGPoint(x: right, y: top)); path.addLine(to: CGPoint(x: right, y: top + length))
        path.move(to: CGPoint(x: left, y: bottom - length)); path.addLine(to: CGPoint(x: left, y: bottom)); path.addLine(to: CGPoint(x: left + length, y: bottom))
        path.move(to: CGPoint(x: right - length, y: bottom)); path.addLine(to: CGPoint(x: right, y: bottom)); path.addLine(to: CGPoint(x: right, y: bottom - length))
        return path
    }
}

enum AeonGlyphKind {
    case sky, library, playlists, settings, star, arrow, files, folder
    case disclosure, picker, export, add, refresh
}

struct AeonGlyph: View {
    let kind: AeonGlyphKind
    var body: some View {
        AeonGlyphPath(kind: kind).stroke(style: AeonOrbit.line)
            .frame(width: 24, height: 24)
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
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            if tier == .filled { AeonGlyph(kind: .star).frame(width: 42) }
            configuration.label
                .font(AeonTheme.FontToken.metric(.caption, weight: .semibold))
                .tracking(1.2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            if tier == .filled { AeonGlyph(kind: .arrow).frame(width: 42) }
        }
        .padding(.horizontal, tier == .filled ? 4 : AeonTheme.Space.regular)
        .padding(.vertical, AeonTheme.Space.medium)
        .frame(minWidth: AeonTheme.Space.minimumTarget, maxWidth: .infinity,
               minHeight: tier == .filled ? 56 : AeonTheme.Space.minimumTarget)
        .foregroundStyle(destructive ? AeonTheme.ColorToken.danger : AeonOrbit.ink)
        .contentShape(Rectangle())
        .background {
            Color.clear
        }
        .overlay {
            if tier != .bare {
                AeonReticleMark(pressed: configuration.isPressed)
                    .stroke(destructive ? AeonTheme.ColorToken.danger : AeonOrbit.ink.opacity(tier == .filled ? 1 : 0.48), style: AeonOrbit.line)
            }
        }
        .opacity(isEnabled ? 1 : 0.42)
        .animation(reduceMotion ? nil : .easeOut(duration: AeonTheme.Duration.press), value: configuration.isPressed)
    }
}

struct AeonToggleStyle: ToggleStyle {
    var showsLabel = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: AeonTheme.Space.regular) {
                if showsLabel {
                    configuration.label
                    Spacer(minLength: AeonTheme.Space.small)
                }
                HStack(spacing: AeonTheme.Space.small) {
                    Text("OFF").foregroundStyle(configuration.isOn ? AeonOrbit.secondary : AeonOrbit.ink)
                    Text("ON").foregroundStyle(configuration.isOn ? AeonOrbit.ink : AeonOrbit.secondary)
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
                    Button { selection = value } label: {
                        Text(label(value).uppercased())
                            .font(.system(size: min(metricSize, 17), weight: .medium, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .foregroundStyle(selection == value ? AeonOrbit.ink : AeonOrbit.secondary)
                            .frame(width: cellWidth, height: 48)
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
                    AeonReticleMark().stroke(AeonOrbit.ink, style: AeonOrbit.line)
                        .frame(width: cellWidth, height: 48)
                        .offset(x: -geometry.size.width / 2 + cellWidth * (CGFloat(index) + 0.5))
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
                                Image(systemName: "xmark").frame(width: 44, height: 44)
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
            .overlay(AeonReticleMark().stroke(AeonOrbit.ink.opacity(0.34), style: AeonOrbit.line))
        }
        .buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
}

private struct AeonImportContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct AeonToast: View {
    let message: String
    var body: some View {
        AeonGlass {
            Text(message).font(AeonTheme.FontToken.ui(.callout, weight: .regular)).foregroundStyle(AeonOrbit.ink)
                .padding(.horizontal, AeonTheme.Space.large).frame(minHeight: AeonTheme.Space.minimumTarget)
        }.accessibilityAddTraits(.updatesFrequently)
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
