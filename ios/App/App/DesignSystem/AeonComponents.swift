import Dispatch
import SwiftUI
import UIKit

/// One line language for orbital controls and the hand-drawn navigation glyphs.
enum AeonOrbit {
    static let stroke: CGFloat = 1.125
    static let line = StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
    static let title = AeonTheme.ColorToken.bone
    static let ink = AeonTheme.ColorToken.bone
    static let secondary = AeonTheme.ColorToken.boneSecondary
    static let activeFill = AeonTheme.ColorToken.bone.opacity(0.12)
}

/// A capsule perimeter with complete overlapping ovals, never a stack of pill buttons.
/// `action` reserves narrow end chambers; `equal` fits any number of control options.
struct AeonSegmentedCapsule: Shape {
    enum Layout { case action, equal }
    enum Part { case outline, chamber(Int), knob }
    var chamberCount = 3
    var layout: Layout = .action
    var endWidth: CGFloat = 42
    var part: Part = .outline
    var knobPosition: CGFloat = 0

    var animatableData: CGFloat {
        get { knobPosition }
        set { knobPosition = newValue }
    }

    func path(in bounds: CGRect) -> Path {
        let rect = bounds.insetBy(dx: AeonOrbit.stroke / 2, dy: AeonOrbit.stroke / 2)
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let count = max(2, chamberCount)
        let outer = Path(roundedRect: rect, cornerRadius: rect.height / 2)
        let cell = rect.width / CGFloat(count)
        let oval: (Int) -> CGRect = { index in
            if self.layout == .action && count == 3 {
                let inset = min(self.endWidth + 4, rect.width * 0.25)
                return rect.insetBy(dx: inset, dy: 0)
            }
            return CGRect(x: rect.minX + CGFloat(index) * cell - cell * 0.08,
                          y: rect.minY, width: cell * 1.16, height: rect.height)
        }
        switch part {
        case .outline:
            var path = outer
            if count == 2 {
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                              control1: CGPoint(x: rect.midX - rect.height * 0.15, y: rect.minY + rect.height * 0.3),
                              control2: CGPoint(x: rect.midX + rect.height * 0.15, y: rect.maxY - rect.height * 0.3))
            } else {
                for index in 1..<(count - 1) { path.addEllipse(in: oval(index)) }
            }
            return path
        case .knob:
            let inset = rect.height * 0.12
            let width = max(0, cell - inset * 2)
            return Path(ellipseIn: CGRect(x: rect.minX + inset + min(1, max(0, knobPosition)) * cell,
                                         y: rect.minY + inset, width: width, height: rect.height - inset * 2))
        case .chamber(let index):
            guard (0..<count).contains(index) else { return Path() }
            if count == 2 {
                return endChamber(in: rect, boundary: rect.midX, right: index == 1)
            }
            if index > 0 && index < count - 1 { return Path(ellipseIn: oval(index)) }
            let adjacent = oval(index == 0 ? 1 : count - 2)
            return lens(in: rect, oval: adjacent, right: index == count - 1)
        }
    }

    private func endChamber(in rect: CGRect, boundary: CGFloat, right: Bool) -> Path {
        let half = CGRect(x: right ? boundary : rect.minX, y: rect.minY,
                          width: right ? rect.maxX - boundary : boundary - rect.minX, height: rect.height)
        // Only the selected half is shaded; the traveling oval remains a separate stroke.
        return Path(roundedRect: half.insetBy(dx: 1, dy: 1), cornerRadius: min(half.width, half.height) / 2)
    }

    private func lens(in rect: CGRect, oval: CGRect, right: Bool) -> Path {
        // Follow one outside end and the adjacent oval's inner half. No whole-control fill.
        let r = min(rect.height / 2, rect.width / 2)
        let sign: CGFloat = right ? -1 : 1
        let end = right ? rect.maxX : rect.minX
        let cap = end + sign * r
        let join = oval.midX
        let tip = right ? oval.maxX : oval.minX
        let k: CGFloat = 0.5522847498
        var path = Path()
        path.move(to: CGPoint(x: join, y: rect.minY))
        path.addLine(to: CGPoint(x: cap, y: rect.minY))
        path.addCurve(to: CGPoint(x: end, y: rect.midY),
                      control1: CGPoint(x: cap - sign * r * k, y: rect.minY),
                      control2: CGPoint(x: end, y: rect.midY - r * k))
        path.addCurve(to: CGPoint(x: cap, y: rect.maxY),
                      control1: CGPoint(x: end, y: rect.midY + r * k),
                      control2: CGPoint(x: cap - sign * r * k, y: rect.maxY))
        path.addLine(to: CGPoint(x: join, y: rect.maxY))
        path.addCurve(to: CGPoint(x: tip, y: rect.midY),
                      control1: CGPoint(x: join + (tip - join) * k, y: rect.maxY),
                      control2: CGPoint(x: tip, y: rect.midY + rect.height * k / 2))
        path.addCurve(to: CGPoint(x: join, y: rect.minY),
                      control1: CGPoint(x: tip, y: rect.midY - rect.height * k / 2),
                      control2: CGPoint(x: join + (tip - join) * k, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

enum AeonGlyphKind { case sky, library, playlists, settings, star, arrow, files, folder }

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
            if tier == .filled && configuration.isPressed {
                AeonSegmentedCapsule(part: .chamber(1)).fill(AeonOrbit.activeFill)
            } else if tier == .hairline && configuration.isPressed {
                Rectangle().fill(AeonOrbit.activeFill)
            }
        }
        .overlay {
            if tier == .filled {
                AeonSegmentedCapsule().stroke(AeonOrbit.ink.opacity(0.82), style: AeonOrbit.line)
            } else if tier == .hairline {
                Rectangle().stroke(destructive ? AeonTheme.ColorToken.danger.opacity(0.72) : AeonOrbit.ink.opacity(0.4),
                                   style: AeonOrbit.line)
            }
        }
        .opacity(isEnabled ? 1 : 0.42)
        .animation(reduceMotion ? nil : .easeOut(duration: AeonTheme.Duration.press), value: configuration.isPressed)
    }
}

struct AeonToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: AeonTheme.Space.regular) {
            configuration.label
            Spacer(minLength: AeonTheme.Space.small)
            Button { configuration.isOn.toggle() } label: {
                ZStack {
                    AeonSegmentedCapsule(chamberCount: 2, layout: .equal,
                                         part: .chamber(configuration.isOn ? 1 : 0))
                        .fill(AeonOrbit.activeFill)
                    AeonSegmentedCapsule(chamberCount: 2, layout: .equal)
                        .stroke(AeonOrbit.ink.opacity(0.4), style: AeonOrbit.line)
                    AeonSegmentedCapsule(chamberCount: 2, layout: .equal, part: .knob,
                                         knobPosition: configuration.isOn ? 1 : 0)
                        .stroke(AeonOrbit.ink, style: AeonOrbit.line)
                    HStack(spacing: 0) {
                        Text("−").frame(maxWidth: .infinity)
                        Text("+").frame(maxWidth: .infinity)
                    }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(AeonOrbit.ink.opacity(0.85))
                }
                .frame(width: 88, height: 38)
                .frame(minHeight: AeonTheme.Space.minimumTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : .easeInOut(duration: AeonTheme.Duration.chrome), value: configuration.isOn)
        }
        .opacity(isEnabled ? 1 : 0.42)
        // Retain native switch semantics and activation, rather than announcing a decorative button.
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
        HStack(spacing: 0) {
            ForEach(values, id: \.self) { value in
                Button { selection = value } label: {
                    Text(label(value).uppercased())
                        .font(.system(size: min(metricSize, 17), weight: .semibold, design: .monospaced))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(selection == value ? AeonOrbit.ink : AeonOrbit.secondary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(spokenLabel?(value) ?? label(value))
                .accessibilityAddTraits(selection == value ? .isSelected : [])
                .accessibilityIdentifier(identifier(value))
            }
        }
        .background {
            if let index = values.firstIndex(of: selection) {
                AeonSegmentedCapsule(chamberCount: values.count, layout: .equal, part: .chamber(index))
                    .fill(AeonOrbit.activeFill)
            }
        }
        .overlay {
            AeonSegmentedCapsule(chamberCount: values.count, layout: .equal)
                .stroke(AeonOrbit.ink.opacity(0.72), style: AeonOrbit.line)
                .allowsHitTesting(false)
        }
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
        .frame(width: size, height: size).clipShape(Circle())
        .overlay(Circle().stroke(AeonOrbit.ink.opacity(0.28), style: AeonOrbit.line))
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

struct AeonEmptyState: View {
    let title: String
    let detail: String?
    let actionTitle: String?
    let action: (() -> Void)?
    var body: some View {
        VStack(spacing: AeonTheme.Space.large) {
            AeonRouteMark()
            AeonDisplayText(title, size: 30).multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(AeonTheme.FontToken.ui(.callout))
                    .foregroundStyle(AeonOrbit.secondary).multilineTextAlignment(.center)
            }
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(AeonButtonStyle(tier: .filled)) }
        }
        .foregroundStyle(AeonOrbit.title).padding(AeonTheme.Space.large)
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
    let selectFolder: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        AeonSheet {
            ScrollView {
                VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                    VStack(alignment: .leading, spacing: AeonTheme.Space.regular) {
                        AeonBreadcrumb(text: "Import")
                        AeonDisplayText("Choose a source", size: 32, maximumLines: 2).foregroundStyle(AeonOrbit.title)
                        Text("Aeon only reads what you hand it.")
                            .font(AeonTheme.FontToken.ui(.callout)).foregroundStyle(AeonOrbit.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: AeonTheme.Space.medium) {
                        importOption(title: "Files", detail: "Choose one or more supported audio files.", glyph: .files,
                                     identifier: "aeon.library.import.files", action: selectFiles)
                        importOption(title: "Folder", detail: "Choose a music folder in Files.", glyph: .folder,
                                     identifier: "aeon.library.import.folder", action: selectFolder)
                    }
                }
                .padding(.horizontal, AeonTheme.Space.edge).padding(.bottom, AeonTheme.Space.large)
            }
            .scrollIndicators(.hidden)
        }
        .presentationDetents([.medium, .large])
        .accessibilityElement(children: .contain).accessibilityIdentifier("aeon.import.sheet")
    }
    private func importOption(title: String, detail: String, glyph: AeonGlyphKind,
                              identifier: String, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + AeonTheme.Duration.chrome) { action() }
        } label: {
            HStack(spacing: AeonTheme.Space.regular) {
                AeonGlyph(kind: glyph).foregroundStyle(AeonOrbit.ink.opacity(0.78)).frame(width: 28)
                VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                    Text(title).font(AeonTheme.FontToken.ui(.callout, weight: .semibold)).foregroundStyle(AeonTheme.ColorToken.textPrimary)
                    Text(detail).font(AeonTheme.FontToken.ui(.caption)).foregroundStyle(AeonOrbit.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AeonTheme.Space.small)
                AeonGlyph(kind: .arrow).foregroundStyle(AeonOrbit.ink.opacity(0.6))
            }
            .padding(AeonTheme.Space.regular).frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(Rectangle().stroke(AeonOrbit.ink.opacity(0.34), style: AeonOrbit.line))
        }
        .buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
}

struct AeonToast: View {
    let message: String
    var body: some View {
        AeonGlass {
            Text(message).font(AeonTheme.FontToken.ui(.callout, weight: .medium)).foregroundStyle(AeonOrbit.ink)
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
