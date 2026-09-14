import Dispatch
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
        let opaque = reduceTransparency || AeonTestOverrides.reduceTransparency
        let increasedContrast = contrast == .increased || AeonTestOverrides.increasedContrast
        content
            .background {
                ZStack {
                    if opaque {
                        AeonTheme.ColorToken.chamberOpaque
                    } else {
                        AeonBlur(style: .systemUltraThinMaterialDark)
                        AeonTheme.ColorToken.chamber.opacity(increasedContrast ? 0.88 : 0.72)
                        artworkTint?.opacity(0.055)
                    }
                }
            }
            .overlay(
                Rectangle().stroke(
                    increasedContrast ? AeonTheme.ColorToken.strongRule : AeonTheme.ColorToken.rule,
                    lineWidth: AeonTheme.Stroke.hairline
                )
            )
            .shadow(color: .black.opacity(0.34), radius: AeonTheme.Shadow.glassRadius, y: AeonTheme.Shadow.glassY)
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
            .lineLimit(nil)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, AeonTheme.Space.regular)
            .frame(
                minWidth: AeonTheme.Space.minimumTarget,
                maxWidth: .infinity,
                minHeight: AeonTheme.Space.minimumTarget
            )
            .background {
                if tier != .bare {
                    RoundedRectangle(cornerRadius: AeonTheme.Radius.control, style: .continuous)
                        .fill(background.opacity(configuration.isPressed ? 0.82 : 1))
                }
            }
            .overlay {
                if tier == .hairline {
                    RoundedRectangle(cornerRadius: AeonTheme.Radius.control, style: .continuous)
                        .stroke(border, lineWidth: AeonTheme.Stroke.hairline)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: AeonTheme.Duration.press), value: configuration.isPressed)
            .opacity(isEnabled ? 1 : 0.42)
    }

    private var foreground: Color {
        if destructive { return AeonTheme.ColorToken.danger }
        return tier == .filled ? AeonTheme.ColorToken.void : AeonTheme.ColorToken.bone
    }

    private var background: Color {
        tier == .filled ? AeonTheme.ColorToken.bone : AeonTheme.ColorToken.surfaceSelected.opacity(0.72)
    }

    private var border: Color {
        destructive ? AeonTheme.ColorToken.danger.opacity(0.72) : AeonTheme.ColorToken.rule
    }
}

// Kept for compatibility with older feature views. New settings surfaces use the
// native SwiftUI switch style directly so VoiceOver and platform behavior stay native.
struct AeonToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: configuration.$isOn) { configuration.label }
            .toggleStyle(.switch)
            .tint(AeonTheme.ColorToken.bone)
    }
}

struct AeonSegment<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: AeonTheme.Space.xSmall) {
            ForEach(values, id: \.self) { value in
                Button(label(value).uppercased()) { selection = value }
                    .font(AeonTheme.FontToken.metric(.caption2, weight: .semibold))
                    .foregroundStyle(selection == value ? AeonTheme.ColorToken.void : AeonTheme.ColorToken.boneSecondary)
                    .frame(maxWidth: .infinity, minHeight: AeonTheme.Space.minimumTarget)
                    .background {
                        RoundedRectangle(cornerRadius: AeonTheme.Radius.compact, style: .continuous)
                            .fill(selection == value ? AeonTheme.ColorToken.bone : .clear)
                    }
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(AeonTheme.Space.xSmall)
        .background(
            RoundedRectangle(cornerRadius: AeonTheme.Radius.control, style: .continuous)
                .fill(AeonTheme.ColorToken.surfaceSelected.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AeonTheme.Radius.control, style: .continuous)
                .stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline)
        )
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
            VStack(alignment: .leading, spacing: AeonTheme.Space.xSmall) {
                Text(title)
                    .font(AeonTheme.FontToken.ui(.body, weight: .medium))
                    .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(AeonTheme.FontToken.ui(.caption))
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AeonTheme.Space.small)
            trailing
        }
        .padding(.vertical, AeonTheme.Space.small)
        .frame(minHeight: 62)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
        }
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
            if let image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "circle.grid.cross")
                    .font(.system(size: size * 0.24, weight: .ultraLight))
                    .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline))
        .background(
            Rectangle()
                .stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline)
                .offset(x: AeonTheme.Stroke.artworkOffset, y: AeonTheme.Stroke.artworkOffset)
        )
        .shadow(color: .black.opacity(0.52), radius: AeonTheme.Shadow.artworkRadius, y: AeonTheme.Shadow.artworkY)
    }
}

struct AeonSheet<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(AeonTheme.ColorToken.boneSecondary.opacity(0.74))
                .frame(width: 34, height: 3)
                .padding(.vertical, AeonTheme.Space.medium)
            content
        }
        .frame(maxWidth: AeonTheme.Space.textContentMaximum)
        .background(AeonTheme.ColorToken.chamberOpaque)
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
            AeonDisplayText(title, size: 34)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(AeonTheme.FontToken.ui(.body))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(AeonButtonStyle(tier: .filled))
            }
        }
        .foregroundStyle(AeonTheme.ColorToken.bone)
        .padding(AeonTheme.Space.section)
    }
}

struct AeonRouteMark: View {
    var width: CGFloat = 68
    var height: CGFloat = 48

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
            context.stroke(path, with: .color(AeonTheme.ColorToken.ivorySecondary.opacity(0.72)), lineWidth: 0.75)
            for (index, point) in points.enumerated() {
                let radius: CGFloat = index == points.count - 1 ? 3.5 : 2.2
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(index == points.count - 1 ? AeonTheme.ColorToken.bone : AeonTheme.ColorToken.ivorySecondary)
                )
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

struct AeonImportSheet: View {
    let selectFiles: () -> Void
    let selectFolder: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AeonSheet {
            VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                    AeonLabel(text: "Bring music into Aeon")
                    AeonDisplayText("Choose a source", size: 32, maximumLines: 2)
                        .foregroundStyle(AeonTheme.ColorToken.bone)
                    Text("Aeon reads the music you choose without pretending it can browse every location on your device.")
                        .font(AeonTheme.FontToken.ui(.body))
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                importOption(
                    title: "Files",
                    detail: "Choose one or more supported audio files.",
                    symbol: "waveform",
                    identifier: "aeon.library.import.files",
                    action: selectFiles
                )
                importOption(
                    title: "Folder",
                    detail: "Choose a folder from a location iOS allows Aeon to access.",
                    symbol: "folder",
                    identifier: "aeon.library.import.folder",
                    action: selectFolder
                )
            }
            .padding(.horizontal, AeonTheme.Space.edge)
            .padding(.bottom, AeonTheme.Space.edge)
        }
        .presentationDetents([.medium])
        .accessibilityIdentifier("aeon.import.sheet")
    }

    private func importOption(
        title: String,
        detail: String,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + AeonTheme.Duration.chrome) {
                action()
            }
        } label: {
            HStack(spacing: AeonTheme.Space.regular) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(AeonTheme.ColorToken.ivorySecondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: AeonTheme.Space.xSmall) {
                    Text(title)
                        .font(AeonTheme.FontToken.ui(.body, weight: .semibold))
                        .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                    Text(detail)
                        .font(AeonTheme.FontToken.ui(.caption))
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AeonTheme.Space.small)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
            }
            .padding(.horizontal, AeonTheme.Space.regular)
            .padding(.vertical, AeonTheme.Space.medium)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AeonTheme.Radius.surface, style: .continuous)
                    .fill(AeonTheme.ColorToken.surfaceSelected.opacity(0.76))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AeonTheme.Radius.surface, style: .continuous)
                    .stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
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
                Capsule()
                    .fill(AeonTheme.ColorToken.bone)
                    .frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 2)
        .accessibilityValue("\(Int(min(1, max(0, value)) * 100)) percent")
    }
}
