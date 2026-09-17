import Combine
import SwiftUI
import UIKit

enum AeonDestination: String, CaseIterable, Identifiable {
    case sky
    case library
    case playlists
    case settings

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
    var symbol: String {
        switch self {
        case .sky: return "sparkles"
        case .library: return "square.grid.2x2"
        case .playlists: return "point.3.connected.trianglepath.dotted"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct AeonArtworkTintHost<Content: View>: View {
    @ObservedObject var playback: PlaybackController
    let catalog: CatalogRepository
    let artworkStore: ArtworkStore
    let content: Content
    @State private var tint: Color?

    init(
        playback: PlaybackController,
        catalog: CatalogRepository,
        artworkStore: ArtworkStore,
        @ViewBuilder content: () -> Content
    ) {
        self.playback = playback
        self.catalog = catalog
        self.artworkStore = artworkStore
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.aeonArtworkTint, tint)
            .onReceive(playback.$snapshot.map { $0?.trackID }.removeDuplicates()) { trackID in
                tint = resolvedTint(trackID: trackID)
            }
    }

    private func resolvedTint(trackID: String?) -> Color? {
        AeonArtworkTint.resolve(trackID: trackID, catalog: catalog, artworkStore: artworkStore)
            .map(Color.init(uiColor:))
    }
}

struct AeonChrome<PlayerBar: View>: View {
    @Binding var destination: AeonDestination
    @Binding var portraitSidebarVisible: Bool
    let playerLoaded: Bool
    let playerBar: PlayerBar
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.aeonArtworkTint) private var artworkTint

    init(
        destination: Binding<AeonDestination>,
        portraitSidebarVisible: Binding<Bool>,
        playerLoaded: Bool,
        @ViewBuilder playerBar: () -> PlayerBar
    ) {
        _destination = destination
        _portraitSidebarVisible = portraitSidebarVisible
        self.playerLoaded = playerLoaded
        self.playerBar = playerBar()
    }

    var body: some View {
        GeometryReader { geometry in
            let regular = horizontalSizeClass == .regular
            let landscape = geometry.size.width > geometry.size.height
            ZStack(alignment: .topLeading) {
                if regular && landscape {
                    sidebar
                        .frame(width: AeonTheme.Space.sidebar)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .leading))
                } else if regular {
                    if portraitSidebarVisible {
                        sidebar
                            .frame(width: AeonTheme.Space.sidebar)
                            .frame(maxHeight: .infinity)
                            .transition(.move(edge: .leading))
                    }
                    if playerLoaded && !portraitSidebarVisible {
                        portraitPlayerBar(
                            width: min(
                                AeonTheme.Space.sidePanel,
                                geometry.size.width - (AeonTheme.Space.edge * 2)
                            ),
                            height: max(0, geometry.size.height - geometry.safeAreaInsets.bottom),
                            leadingInset: max(AeonTheme.Space.edge, geometry.safeAreaInsets.leading)
                        )
                        .transition(.move(edge: .bottom))
                    }
                    Button {
                        portraitSidebarVisible.toggle()
                    } label: {
                        Image(systemName: portraitSidebarVisible ? "xmark" : "line.3.horizontal")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                    .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                    .background(
                        RoundedRectangle(cornerRadius: AeonTheme.Radius.compact, style: .continuous)
                            .fill(AeonTheme.ColorToken.chamberOpaque)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AeonTheme.Radius.compact, style: .continuous)
                            .stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline)
                    )
                    .padding(.leading, max(AeonTheme.Space.edge, geometry.safeAreaInsets.leading))
                    .padding(.top, max(AeonTheme.Space.small, geometry.safeAreaInsets.top))
                    .accessibilityLabel(portraitSidebarVisible ? "Close navigation" : "Open navigation")
                    .accessibilityIdentifier("aeon.navigation.menu")
                } else {
                    compactChrome(bottomInset: geometry.safeAreaInsets.bottom)
                }
            }
            .animation(.easeOut(duration: AeonTheme.Duration.chrome), value: portraitSidebarVisible)
        }
        .zIndex(AeonTheme.Layer.chrome)
    }

    private func compactChrome(bottomInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer()
            if playerLoaded {
                Rectangle()
                    .fill(AeonTheme.ColorToken.rule)
                    .frame(height: AeonTheme.Stroke.hairline)
                playerBar.frame(minHeight: AeonTheme.Space.playerBar)
            }
            AeonGlass {
                HStack(spacing: 0) {
                    ForEach(AeonDestination.allCases) { item in
                        navigationButton(item, compact: true)
                    }
                }
                .padding(.horizontal, AeonTheme.Space.xSmall)
                .padding(.bottom, bottomInset)
                .frame(minHeight: AeonTheme.Space.compactDock + bottomInset)
            }
        }
    }

    private func portraitPlayerBar(width: CGFloat, height: CGFloat, leadingInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer()
            Rectangle()
                .fill(AeonTheme.ColorToken.rule)
                .frame(height: AeonTheme.Stroke.hairline)
            playerBar.frame(minHeight: AeonTheme.Space.playerBar)
        }
        .frame(width: width, height: height)
        .padding(.leading, leadingInset)
    }

    private var sidebar: some View {
        AeonGlass {
            VStack(alignment: .leading, spacing: 0) {
                AeonDisplayText("AEON", size: 28, maximumLines: 1)
                    .tracking(2)
                    .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                    .padding(.horizontal, AeonTheme.Space.edge)
                    .padding(.top, 72)
                    .padding(.bottom, AeonTheme.Space.section)
                ForEach(AeonDestination.allCases) { item in
                    navigationButton(item, compact: false)
                }
                Spacer()
                if playerLoaded {
                    Rectangle()
                        .fill(AeonTheme.ColorToken.rule)
                        .frame(height: AeonTheme.Stroke.hairline)
                    playerBar.frame(minHeight: AeonTheme.Space.playerBar)
                }
            }
        }
        .ignoresSafeArea(edges: .vertical)
        .accessibilityElement(children: .contain)
    }

    private func navigationButton(_ item: AeonDestination, compact: Bool) -> some View {
        let selected = destination == item
        return Button {
            destination = item
            portraitSidebarVisible = false
        } label: {
            Group {
                if compact {
                    if dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText {
                        Image(systemName: item.symbol)
                            .font(.system(size: 23, weight: selected ? .medium : .regular))
                            .frame(width: 26, height: 26)
                    } else {
                        VStack(spacing: AeonTheme.Space.xSmall) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 18, weight: selected ? .semibold : .regular))
                                .frame(width: 24, height: 24)
                            Text(item.title)
                                .font(AeonTheme.FontToken.metric(.caption2, weight: selected ? .semibold : .medium))
                        }
                    }
                } else {
                    if dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText {
                        Image(systemName: item.symbol)
                            .font(.system(size: 23, weight: selected ? .medium : .regular))
                            .frame(width: 26, height: 26)
                    } else {
                        HStack(spacing: AeonTheme.Space.medium) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 17, weight: selected ? .semibold : .regular))
                                .frame(width: 24, height: 24)
                            Text(item.title)
                                .font(AeonTheme.FontToken.metric(.caption, weight: selected ? .semibold : .medium))
                            Spacer()
                        }
                        .padding(.horizontal, AeonTheme.Space.edge)
                    }
                }
            }
            .foregroundStyle(selected ? AeonTheme.ColorToken.textPrimary : AeonTheme.ColorToken.boneSecondary)
            .frame(maxWidth: .infinity, minHeight: max(AeonTheme.Space.minimumTarget, compact ? 58 : 52))
            // Hit-test the full label, including empty space around accessibility-sized icons.
            .contentShape(Rectangle())
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: AeonTheme.Radius.compact, style: .continuous)
                        .fill(AeonTheme.ColorToken.surfaceSelected.opacity(compact ? 0.54 : 0.44))
                        .padding(.horizontal, compact ? 6 : 8)
                        .padding(.vertical, compact ? 5 : 3)
                }
            }
            .overlay(alignment: compact ? .top : .leading) {
                Rectangle()
                    .fill(selected ? AeonTheme.ColorToken.bone : .clear)
                    .frame(width: compact ? nil : 2, height: compact ? 2 : nil)
                    .padding(.horizontal, compact ? 16 : 0)
                    .padding(.vertical, compact ? 0 : 11)
            }
        }
        .frame(maxWidth: .infinity, minHeight: max(AeonTheme.Space.minimumTarget, compact ? 58 : 52))
        .buttonStyle(.plain)
        .accessibilityLabel(item.title.capitalized)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("aeon.navigation.\(item.rawValue)")
    }
}

extension AeonChrome where PlayerBar == EmptyView {
    init(destination: Binding<AeonDestination>, portraitSidebarVisible: Binding<Bool>) {
        self.init(
            destination: destination,
            portraitSidebarVisible: portraitSidebarVisible,
            playerLoaded: false
        ) { EmptyView() }
    }
}
