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
                    Button {} label: {
                        Image(systemName: portraitSidebarVisible ? "xmark" : "line.3.horizontal")
                            .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AeonTheme.ColorToken.bone)
                    .background(AeonTheme.ColorToken.chamberOpaque)
                    .overlay(Rectangle().stroke(AeonTheme.ColorToken.rule, lineWidth: AeonTheme.Stroke.hairline))
                    .padding(.leading, max(AeonTheme.Space.edge, geometry.safeAreaInsets.leading))
                    .padding(.top, max(AeonTheme.Space.small, geometry.safeAreaInsets.top))
                    .highPriorityGesture(TapGesture().onEnded { portraitSidebarVisible.toggle() })
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
            VStack(spacing: 0) {
                if playerLoaded {
                    playerBar.frame(minHeight: AeonTheme.Space.playerBar)
                }
                HStack(spacing: 0) {
                    ForEach(AeonDestination.allCases) { item in
                        navigationButton(item, compact: true)
                    }
                }
                .frame(minHeight: AeonTheme.Space.compactDock)
                .padding(.bottom, bottomInset)
            }
            .background(alignment: .bottom) {
                // The only thing beneath the glyphs is a scrim, so the sky
                // keeps running to the bottom edge of the screen.
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.88), .black.opacity(0.94)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: AeonTheme.Space.compactDock
                    + (playerLoaded ? AeonTheme.Space.playerBar : 0)
                    + bottomInset + 70)
                .allowsHitTesting(false)
            }
        }
    }

    private func portraitPlayerBar(width: CGFloat, height: CGFloat, leadingInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer()
            Color.black.opacity(artworkTint == nil ? 0.32 : 0.58).frame(height: 8)
            playerBar.frame(minHeight: AeonTheme.Space.playerBar)
        }
        .frame(width: width, height: height)
        .padding(.leading, leadingInset)
    }

    private var sidebar: some View {
        AeonGlass {
            VStack(alignment: .leading, spacing: 0) {
                AeonDisplayText("Aeon", size: 28, maximumLines: 1)
                    .foregroundStyle(AeonTheme.ColorToken.bone)
                    .padding(.horizontal, AeonTheme.Space.edge)
                    .padding(.top, 72)
                    .padding(.bottom, AeonTheme.Space.section)
                ForEach(AeonDestination.allCases) { item in navigationButton(item, compact: false) }
                Spacer()
                if playerLoaded {
                    Color.black.opacity(artworkTint == nil ? 0.32 : 0.58).frame(height: 8)
                    playerBar.frame(minHeight: AeonTheme.Space.playerBar)
                }
            }
        }
        .ignoresSafeArea(edges: .vertical)
        .accessibilityElement(children: .contain)
    }

    private func navigationButton(_ item: AeonDestination, compact: Bool) -> some View {
        Button {
            destination = item
            portraitSidebarVisible = false
        } label: {
            Group {
                if compact {
                    Image(systemName: item.symbol)
                        .font(.system(
                            size: dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText ? 24 : 18,
                            weight: .regular
                        ))
                        .symbolRenderingMode(.monochrome)
                        .scaleEffect(destination == item ? 1 : 0.94)
                        .animation(AeonTheme.Motion.chrome, value: destination)
                } else {
                    if dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText {
                        Image(systemName: item.symbol)
                            .font(.system(size: 24, weight: .regular))
                    } else {
                        HStack(spacing: AeonTheme.Space.medium) {
                            Image(systemName: item.symbol).frame(width: 24)
                            Text(item.title).font(AeonTheme.FontToken.metric(.caption, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, AeonTheme.Space.edge)
                    }
                }
            }
            .foregroundStyle(destination == item
                ? AeonTheme.ColorToken.bone
                : Color.white.opacity(compact ? 0.20 : 0.62))
            .frame(maxWidth: .infinity, minHeight: max(AeonTheme.Space.minimumTarget, compact ? 58 : 52))
            .background(!compact && destination == item ? AeonTheme.ColorToken.silver.opacity(0.14) : .clear)
            .overlay(alignment: .leading) {
                if !compact {
                    Capsule()
                        .fill(destination == item ? AeonTheme.ColorToken.bone : .clear)
                        .frame(width: 2)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: max(AeonTheme.Space.minimumTarget, compact ? 58 : 52))
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityLabel(item.title.capitalized)
        .accessibilityAddTraits(destination == item ? .isSelected : [])
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
