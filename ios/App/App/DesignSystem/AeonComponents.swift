import SwiftUI
import UIKit

struct AeonScreen<Content: View>: View {
    let playerVisible: Bool
    let content: (AeonReadableInsets) -> Content
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(playerVisible: Bool = false, @ViewBuilder content: @escaping (AeonReadableInsets) -> Content) {
        self.playerVisible = playerVisible
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = horizontalSizeClass == .compact
            let readable = AeonReadableInsets(
                top: geometry.safeAreaInsets.top,
                leading: geometry.safeAreaInsets.leading + (compact ? 0 : AeonTheme.Space.sidebar),
                bottom: geometry.safeAreaInsets.bottom
                    + (compact ? AeonTheme.Space.compactDock : 0)
                    + (compact && playerVisible ? AeonTheme.Space.playerBar : 0),
                trailing: geometry.safeAreaInsets.trailing
            )
            ZStack {
                AeonTheme.ColorToken.void.ignoresSafeArea()
                content(readable)
                    .environment(\.aeonReadableInsets, readable)
            }
        }
    }
}

struct AeonGlass<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.aeonArtworkTint) private var artworkTint
    let radius: CGFloat
    let content: Content

    init(radius: CGFloat = AeonTheme.Radius.large, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }

    var body: some View {
        let opaque = reduceTransparency || AeonTestOverrides.reduceTransparency
        let increasedContrast = contrast == .increased || AeonTestOverrides.increasedContrast
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    if opaque {
                        AeonTheme.ColorToken.chamberOpaque
                    } else {
                        AeonBlur(style: .systemUltraThinMaterialDark)
                        AeonTheme.ColorToken.chamber.opacity(increasedContrast ? 0.72 : 0.34)
                        artworkTint?.opacity(0.06)
                    }
                }
                .clipShape(shape)
            }
            .overlay {
                // The edge does the work a border used to: it catches light on
                // one side, disappears through the middle, and returns faintly.
                shape.strokeBorder(
                    LinearGradient(
                        gradient: increasedContrast
                            ? Gradient(colors: [.white.opacity(0.46), .white.opacity(0.22)])
                            : AeonTheme.ColorToken.edgeHighlight,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.42), radius: AeonTheme.Shadow.glassRadius, y: AeonTheme.Shadow.glassY)
    }
}

private struct AeonBlur: UIViewRepresentable {
    let style: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView { UIVisualEffectView(effect: UIBlurEffect(style: style)) }
    func updateUIView(_ view: UIVisualEffectView, context: Context) { view.effect = UIBlurEffect(style: style) }
}

struct AeonBreadcrumb: View {
    let text: String
    var body: some View {
        HStack(spacing: AeonTheme.Space.medium) {
            Text(text.uppercased())
            Rectangle().frame(height: AeonTheme.Stroke.hairline).opacity(0.28)
        }
        .font(AeonTheme.FontToken.metric(.caption2, weight: .semibold))
        .tracking(AeonTheme.FontToken.labelTracking)
        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
        .frame(minHeight: AeonTheme.Space.minimumTarget)
    }
}

enum AeonButtonTier { case filled, hairline, bare }

struct AeonButtonStyle: ButtonStyle {
    let tier: AeonButtonTier
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AeonTheme.FontToken.metric(.caption, weight: .bold))
            .tracking(AeonTheme.FontToken.labelTracking)
            .textCase(.uppercase)
            .foregroundStyle(foreground)
            .lineLimit(nil)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, AeonTheme.Space.large)
            .frame(
                minWidth: AeonTheme.Space.minimumTarget,
                maxWidth: .infinity,
                minHeight: AeonTheme.Space.minimumTarget
            )
            .background(background.opacity(configuration.isPressed ? 0.72 : 1), in: Capsule())
            .overlay {
                if tier != .bare {
                    Capsule().strokeBorder(border, lineWidth: 1)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(AeonTheme.Motion.control, value: configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.42)
    }

    private var foreground: Color {
        if destructive { return AeonTheme.ColorToken.danger }
        return tier == .filled ? AeonTheme.ColorToken.void : AeonTheme.ColorToken.bone
    }
    private var background: Color {
        tier == .filled ? AeonTheme.ColorToken.bone : Color.white.opacity(0.03)
    }
    private var border: Color {
        destructive ? AeonTheme.ColorToken.danger : AeonTheme.ColorToken.strongRule
    }
}

struct AeonToggleStyle: ToggleStyle {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Group {
                if dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText {
                    VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                        configuration.label
                        toggleIndicator(isOn: configuration.isOn)
                    }
                } else {
                    HStack {
                        configuration.label
                        Spacer()
                        toggleIndicator(isOn: configuration.isOn)
                    }
                }
            }
            .foregroundStyle(AeonTheme.ColorToken.bone)
            .frame(minHeight: AeonTheme.Space.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }

    private func toggleIndicator(isOn: Bool) -> some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? AeonTheme.ColorToken.bone : Color.white.opacity(0.04))
                .overlay(Capsule().strokeBorder(
                    isOn ? AeonTheme.ColorToken.bone : AeonTheme.ColorToken.strongRule,
                    lineWidth: 1
                ))
                .frame(width: 46, height: 27)
            Circle()
                .fill(isOn ? AeonTheme.ColorToken.void : AeonTheme.ColorToken.boneSecondary)
                .frame(width: 19, height: 19)
                .padding(4)
        }
        .animation(AeonTheme.Motion.chrome, value: isOn)
    }
}

struct AeonSegment<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: AeonTheme.Space.small) {
            ForEach(values, id: \.self) { value in
                Button(label(value).uppercased()) { selection = value }
                    .font(AeonTheme.FontToken.metric(.caption2, weight: .semibold))
                    .tracking(AeonTheme.FontToken.labelTracking)
                    .foregroundStyle(selection == value ? AeonTheme.ColorToken.void : AeonTheme.ColorToken.boneSecondary)
                    .frame(maxWidth: .infinity, minHeight: AeonTheme.Space.minimumTarget)
                    .background(selection == value ? AeonTheme.ColorToken.bone : .clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(
                        selection == value ? .clear : AeonTheme.ColorToken.rule,
                        lineWidth: 1
                    ))
                    .animation(AeonTheme.Motion.chrome, value: selection)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
    }
}

struct AeonRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let trailing: Trailing

    init(title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: AeonTheme.Space.medium) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(AeonTheme.FontToken.ui(.body, weight: .semibold)).foregroundStyle(AeonTheme.ColorToken.bone)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(AeonTheme.FontToken.ui(.subheadline))
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                        .lineSpacing(2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AeonTheme.Space.small)
            trailing
        }
        .padding(.vertical, AeonTheme.Space.medium)
        .frame(minHeight: 56)
        .overlay(alignment: .bottom) { AeonDivider() }
    }
}

extension AeonRow where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

struct AeonLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(AeonTheme.FontToken.metric(.caption2, weight: .semibold))
            .tracking(AeonTheme.FontToken.labelTracking)
            .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
    }
}

struct AeonArtwork: View {
    let image: Image?
    let size: CGFloat

    init(image: Image? = nil, size: CGFloat) {
        self.image = image
        self.size = size
    }

    private var radius: CGFloat {
        min(AeonTheme.Radius.large, max(AeonTheme.Radius.small, size * 0.075))
    }

    var body: some View {
        ZStack {
            AeonTheme.ColorToken.chamber
            if let image { image.resizable().scaledToFill() }
            else {
                Image(systemName: "circle.grid.cross")
                    .font(.system(size: size * 0.24, weight: .ultraLight))
                    .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        gradient: AeonTheme.ColorToken.edgeHighlight,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: .black.opacity(0.55), radius: AeonTheme.Shadow.artworkRadius, y: AeonTheme.Shadow.artworkY)
    }
}

struct AeonSheet<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(AeonTheme.ColorToken.silver).frame(width: 34, height: 3).padding(.vertical, 12)
            content
        }
        .frame(maxWidth: AeonTheme.Space.textContentMaximum)
        .background { AeonGlass(radius: AeonTheme.Radius.sheet) { Color.clear } }
        .presentationDragIndicator(.hidden)
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
                Text(detail)
                    .font(AeonTheme.FontToken.ui(.callout))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(AeonButtonStyle(tier: .filled)) }
        }
        .foregroundStyle(AeonTheme.ColorToken.bone)
        .padding(AeonTheme.Space.section)
    }
}

struct AeonRouteMark: View {
    var body: some View {
        Canvas { context, size in
            let points = [
                CGPoint(x: size.width * 0.14, y: size.height * 0.72),
                CGPoint(x: size.width * 0.38, y: size.height * 0.34),
                CGPoint(x: size.width * 0.66, y: size.height * 0.58),
                CGPoint(x: size.width * 0.88, y: size.height * 0.20)
            ]
            var path = Path()
            path.move(to: points[0])
            points.dropFirst().forEach { path.addLine(to: $0) }
            context.stroke(path, with: .color(AeonTheme.ColorToken.boneTertiary), lineWidth: 0.75)
            for (index, point) in points.enumerated() {
                let radius: CGFloat = index == points.count - 1 ? 3.5 : 2.2
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(index == points.count - 1 ? AeonTheme.ColorToken.bone : AeonTheme.ColorToken.boneSecondary)
                )
            }
        }
        .frame(width: 68, height: 48)
        .accessibilityHidden(true)
    }
}

struct AeonToast: View {
    let message: String
    var body: some View {
        AeonGlass {
            Text(message)
                .font(AeonTheme.FontToken.ui(.callout, weight: .medium))
                .foregroundStyle(AeonTheme.ColorToken.bone)
                .padding(.horizontal, AeonTheme.Space.large)
                .frame(minHeight: AeonTheme.Space.minimumTarget)
        }
        .accessibilityAddTraits(.updatesFrequently)
    }
}

struct AeonProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(AeonTheme.ColorToken.rule)
                Capsule().fill(AeonTheme.ColorToken.bone).frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 2)
        .accessibilityValue("\(Int(min(1, max(0, value)) * 100)) percent")
    }
}


/// Rows are separated by a line that fades out rather than boxing them in.
struct AeonDivider: View {
    var body: some View {
        LinearGradient(
            colors: [.white.opacity(0.14), .white.opacity(0.05), .white.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}
