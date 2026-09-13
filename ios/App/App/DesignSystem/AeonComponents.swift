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
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .background {
                ZStack {
                    if reduceTransparency {
                        AeonTheme.ColorToken.chamberOpaque
                    } else {
                        AeonBlur(style: .systemUltraThinMaterialDark)
                        AeonTheme.ColorToken.chamber.opacity(contrast == .increased ? 0.78 : 0.58)
                        artworkTint?.opacity(0.10)
                    }
                    LinearGradient(
                        colors: [.white.opacity(0.07), .clear, .white.opacity(0.025)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .overlay(Rectangle().stroke(contrast == .increased ? AeonTheme.ColorToken.strongRule : AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline))
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
            Rectangle().frame(height: AeonTheme.Stroke.hairline).opacity(0.42)
        }
        .font(AeonTheme.FontToken.metric(.caption, weight: .medium))
        .tracking(1.8)
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
            .font(AeonTheme.FontToken.metric(.caption, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(foreground)
            .padding(.horizontal, AeonTheme.Space.large)
            .frame(minWidth: AeonTheme.Space.minimumTarget, minHeight: AeonTheme.Space.minimumTarget)
            .background(background.opacity(configuration.isPressed ? 0.72 : 1))
            .overlay(Rectangle().stroke(border, lineWidth: tier == .bare ? 0 : AeonTheme.Stroke.hairline))
            .opacity(isEnabled ? 1 : 0.42)
    }

    private var foreground: Color {
        if destructive { return AeonTheme.ColorToken.danger }
        return tier == .filled ? AeonTheme.ColorToken.void : AeonTheme.ColorToken.bone
    }
    private var background: Color { tier == .filled ? AeonTheme.ColorToken.bone : .clear }
    private var border: Color { destructive ? AeonTheme.ColorToken.danger : AeonTheme.ColorToken.rule }
}

struct AeonToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Spacer()
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Rectangle()
                        .fill(configuration.isOn ? AeonTheme.ColorToken.bone : .clear)
                        .overlay(Rectangle().stroke(AeonTheme.ColorToken.strongRule, lineWidth: AeonTheme.Stroke.hairline))
                        .frame(width: 48, height: 28)
                    Rectangle()
                        .fill(configuration.isOn ? AeonTheme.ColorToken.void : AeonTheme.ColorToken.boneSecondary)
                        .frame(width: 20, height: 20)
                        .padding(4)
                }
            }
            .foregroundStyle(AeonTheme.ColorToken.bone)
            .frame(minHeight: AeonTheme.Space.minimumTarget)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct AeonSegment<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(values, id: \.self) { value in
                Button(label(value).uppercased()) { selection = value }
                    .font(AeonTheme.FontToken.metric(.caption2, weight: .semibold))
                    .foregroundStyle(selection == value ? AeonTheme.ColorToken.void : AeonTheme.ColorToken.boneSecondary)
                    .frame(maxWidth: .infinity, minHeight: AeonTheme.Space.minimumTarget)
                    .background(selection == value ? AeonTheme.ColorToken.bone : .clear)
                    .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline))
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
                Text(title).font(AeonTheme.FontToken.ui(.body, weight: .medium)).foregroundStyle(AeonTheme.ColorToken.bone)
                if let detail, !detail.isEmpty {
                    Text(detail).font(AeonTheme.FontToken.ui(.caption)).foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AeonTheme.Space.small)
            trailing
        }
        .padding(.vertical, AeonTheme.Space.small)
        .frame(minHeight: 62)
        .overlay(alignment: .bottom) { Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline) }
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
            .font(AeonTheme.FontToken.metric(.caption2, weight: .medium))
            .tracking(1.5)
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
        .clipped()
        .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline))
        .background(Rectangle().stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline).offset(x: AeonTheme.Stroke.artworkOffset, y: AeonTheme.Stroke.artworkOffset))
        .shadow(color: .black.opacity(0.52), radius: AeonTheme.Shadow.artworkRadius, y: AeonTheme.Shadow.artworkY)
    }
}

struct AeonSheet<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(AeonTheme.ColorToken.boneSecondary).frame(width: 34, height: 3).padding(.vertical, 12)
            content
        }
        .frame(maxWidth: AeonTheme.Space.textContentMaximum)
        .background { AeonGlass { Color.clear } }
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
            Image(systemName: "circle.grid.cross").font(.system(size: 38, weight: .ultraLight))
            AeonDisplayText(title, size: 30).multilineTextAlignment(.center)
            if let detail { Text(detail).font(AeonTheme.FontToken.ui(.body)).foregroundStyle(AeonTheme.ColorToken.boneSecondary).multilineTextAlignment(.center) }
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(AeonButtonStyle(tier: .filled)) }
        }
        .foregroundStyle(AeonTheme.ColorToken.bone)
        .padding(AeonTheme.Space.section)
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
                Rectangle().fill(AeonTheme.ColorToken.rule)
                Rectangle().fill(AeonTheme.ColorToken.bone).frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 2)
        .accessibilityValue("\(Int(min(1, max(0, value)) * 100)) percent")
    }
}
