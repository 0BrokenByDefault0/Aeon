import Combine
import SwiftUI
import UIKit

enum AeonDestination: String, CaseIterable, Identifiable {
    case sky, library, playlists, settings
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
    var glyph: AeonGlyphKind {
        switch self {
        case .sky: return .sky
        case .library: return .library
        case .playlists: return .playlists
        case .settings: return .settings
        }
    }
}

struct AeonArtworkTintHost<Content: View>: View {
    @ObservedObject var playback: PlaybackController
    let catalog: CatalogRepository
    let artworkStore: ArtworkStore
    let content: Content
    @State private var tint: Color?
    init(playback: PlaybackController, catalog: CatalogRepository, artworkStore: ArtworkStore,
         @ViewBuilder content: () -> Content) {
        self.playback = playback; self.catalog = catalog; self.artworkStore = artworkStore; self.content = content()
    }
    var body: some View {
        content.environment(\.aeonArtworkTint, tint)
            .onReceive(playback.$snapshot.map { $0?.trackID }.removeDuplicates()) { trackID in
                tint = AeonArtworkTint.resolve(trackID: trackID, catalog: catalog, artworkStore: artworkStore)
                    .map(Color.init(uiColor:))
            }
    }
}

struct AeonChrome<PlayerBar: View>: View {
    @Binding var destination: AeonDestination
    @Binding var portraitSidebarVisible: Bool
    let playerLoaded: Bool
    let playerBar: PlayerBar
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(destination: Binding<AeonDestination>, portraitSidebarVisible: Binding<Bool>, playerLoaded: Bool,
         @ViewBuilder playerBar: () -> PlayerBar) {
        _destination = destination; _portraitSidebarVisible = portraitSidebarVisible
        self.playerLoaded = playerLoaded; self.playerBar = playerBar()
    }
    var body: some View {
        GeometryReader { geometry in
            let regular = horizontalSizeClass == .regular
            let landscape = geometry.size.width > geometry.size.height
            ZStack(alignment: .topLeading) {
                if regular && landscape {
                    sidebar.frame(width: AeonTheme.Space.sidebar).frame(maxHeight: .infinity)
                } else if regular {
                    if portraitSidebarVisible {
                        sidebar.frame(width: AeonTheme.Space.sidebar).frame(maxHeight: .infinity)
                            .transition(.move(edge: .leading))
                    }
                    if playerLoaded && !portraitSidebarVisible {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
                            playerBar.frame(minHeight: AeonTheme.Space.playerBar)
                        }
                        .frame(width: min(AeonTheme.Space.sidePanel, geometry.size.width - AeonTheme.Space.edge * 2),
                               height: max(0, geometry.size.height - geometry.safeAreaInsets.bottom))
                        .padding(.leading, max(AeonTheme.Space.edge, geometry.safeAreaInsets.leading))
                        .transition(.move(edge: .bottom))
                    }
                    Button { portraitSidebarVisible.toggle() } label: {
                        Image(systemName: portraitSidebarVisible ? "xmark" : "line.3.horizontal")
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(AeonOrbit.ink)
                    .background(AeonTheme.ColorToken.void)
                    .overlay(Rectangle().stroke(AeonOrbit.ink.opacity(0.35), style: AeonOrbit.line))
                    .padding(.leading, max(AeonTheme.Space.edge, geometry.safeAreaInsets.leading))
                    .padding(.top, max(AeonTheme.Space.small, geometry.safeAreaInsets.top))
                    .accessibilityLabel(portraitSidebarVisible ? "Close navigation" : "Open navigation")
                    .accessibilityIdentifier("aeon.navigation.menu")
                } else {
                    compactChrome
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
                }
            }
            // Bound chrome to the proposed viewport, not the intrinsic height of AX-sized content.
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .animation(reduceMotion ? nil : .easeOut(duration: AeonTheme.Duration.chrome), value: portraitSidebarVisible)
        }
        .zIndex(AeonTheme.Layer.chrome)
    }

    private var compactChrome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if playerLoaded {
                Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
                playerBar.frame(minHeight: AeonTheme.Space.playerBar)
                    .background(AeonTheme.ColorToken.void)
            }
            HStack(spacing: 0) {
                ForEach(AeonDestination.allCases) { navigationButton($0, compact: true) }
            }
            .padding(.horizontal, AeonTheme.Space.xSmall)
            .frame(height: AeonTheme.Space.compactDock)
            .background {
                // Extend only the opaque background through the home-indicator area.
                // Do not add that inset to the controls again: the parent is already safe-area sized.
                AeonTheme.ColorToken.void.ignoresSafeArea(.container, edges: .bottom)
            }
            .overlay(alignment: .top) {
                Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("aeon.navigation.dock")
        }
    }

    private var sidebar: some View {
        AeonGlass {
            VStack(alignment: .leading, spacing: 0) {
                AeonDisplayText("AEON", size: 28, maximumLines: 1).tracking(2).foregroundStyle(AeonOrbit.title)
                    .padding(.horizontal, AeonTheme.Space.edge).padding(.top, 72).padding(.bottom, AeonTheme.Space.section)
                ForEach(AeonDestination.allCases) { navigationButton($0, compact: false) }
                Spacer(minLength: 0)
                if playerLoaded {
                    Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
                    playerBar.frame(minHeight: AeonTheme.Space.playerBar)
                }
            }
        }
        .ignoresSafeArea(edges: .vertical).accessibilityElement(children: .contain)
    }

    private func navigationButton(_ item: AeonDestination, compact: Bool) -> some View {
        let selected = destination == item
        let largeText = dynamicTypeSize.isAccessibilitySize || AeonTestOverrides.accessibilityText
        return Button {
            destination = item; portraitSidebarVisible = false
        } label: {
            Group {
                if largeText {
                    AeonGlyph(kind: item.glyph).foregroundStyle(AeonOrbit.secondary)
                } else if compact {
                    VStack(spacing: AeonTheme.Space.xSmall) {
                        AeonGlyph(kind: item.glyph).foregroundStyle(AeonOrbit.secondary)
                        Text(item.title).font(AeonTheme.FontToken.metric(.caption2, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? AeonOrbit.ink : AeonOrbit.secondary)
                    }
                } else {
                    HStack(spacing: AeonTheme.Space.medium) {
                        AeonGlyph(kind: item.glyph).foregroundStyle(AeonOrbit.secondary)
                        Text(item.title).font(AeonTheme.FontToken.metric(.caption, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? AeonOrbit.ink : AeonOrbit.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, AeonTheme.Space.edge)
                }
            }
            .frame(maxWidth: .infinity, minHeight: compact ? 58 : 52)
            .contentShape(Rectangle())
            .overlay(alignment: compact ? .top : .leading) {
                if compact {
                    AeonTabSelectionRule()
                        .stroke(selected ? AeonOrbit.ink : .clear, style: AeonOrbit.line)
                        .frame(height: AeonOrbit.stroke)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                } else {
                    Rectangle().fill(selected ? AeonOrbit.ink : .clear)
                        .frame(width: AeonOrbit.stroke)
                        .padding(.vertical, 11)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain).frame(maxWidth: .infinity, minHeight: compact ? 58 : 52)
        .accessibilityLabel(item.title.capitalized).accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("aeon.navigation.\(item.rawValue)")
    }
}

extension AeonChrome where PlayerBar == EmptyView {
    init(destination: Binding<AeonDestination>, portraitSidebarVisible: Binding<Bool>) {
        self.init(destination: destination, portraitSidebarVisible: portraitSidebarVisible, playerLoaded: false) { EmptyView() }
    }
}

/// The indicator is centered in its own tab's bounds, including the first (Sky) tab.
struct AeonTabSelectionRule: Shape {
    func path(in rect: CGRect) -> Path {
        let width = min(24, max(0, rect.width))
        let y = rect.minY + AeonOrbit.stroke / 2
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - width / 2, y: y))
        path.addLine(to: CGPoint(x: rect.midX + width / 2, y: y))
        return path
    }
}
