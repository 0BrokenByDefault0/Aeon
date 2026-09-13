import SwiftUI

struct SkyScreen: View {
    @ObservedObject var controller: SkySceneController
    let importProgress: LibraryImportProgress?
    let importFiles: () -> Void
    let importFolder: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                SkyMetalView(controller: controller)
                    .ignoresSafeArea()
                    .opacity(controller.cameraCrossfade ? 0.28 : 1)
                    .animation(.linear(duration: 0.12), value: controller.cameraCrossfade)
                SkyLabelOverlay(controller: controller, viewport: geometry.size)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                SkyAccessibilityOverlay(controller: controller)
                    .allowsHitTesting(false)
                SkyHUD(controller: controller, importProgress: importProgress, viewportSize: geometry.size)
                    .padding(.horizontal, 18)
                    .padding(.top, max(8, geometry.safeAreaInsets.top))
                    .padding(.bottom, max(8, geometry.safeAreaInsets.bottom))
                if controller.catalogue.stars.isEmpty { emptyState }
                if let ceremony = controller.ceremony {
                    VStack(spacing: 5) {
                        Text("CELESTIAL EVENT")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .tracking(1.8)
                        Text(ceremony)
                            .font(.system(size: 24, weight: .regular, design: .serif))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(Color.black.opacity(0.78))
                    .overlay(Rectangle().stroke(.white.opacity(0.22), lineWidth: 0.5))
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityAddTraits(.updatesFrequently)
                }
                selectionLabel
            }
            .background(Color.black)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 15) {
            Text("A place for your records.")
                .font(.system(size: 30, weight: .regular, design: .serif))
            Text("Bring albums in and Aeon will chart them without changing the files you chose.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button("IMPORT FILES", action: importFiles)
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .accessibilityIdentifier("aeon.library.import.files")
                Button("IMPORT FOLDER", action: importFolder)
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityIdentifier("aeon.library.import.folder")
            }
        }
        .padding(28)
        .foregroundStyle(.white)
        .background(Color.black.opacity(0.76))
        .overlay(Rectangle().stroke(.white.opacity(0.2), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("aeon.sky.empty")
    }

    @ViewBuilder
    private var selectionLabel: some View {
        if let planet = controller.selectedPlanet {
            VStack {
                Spacer()
                Text("WORLD \(planet.index) · \(planet.members.count) ALBUMS")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.74))
                    .overlay(Rectangle().stroke(.white.opacity(0.24), lineWidth: 0.5))
                    .accessibilityIdentifier("aeon.sky.planet-selection")
            }
            .padding(.bottom, 24)
        } else if let star = controller.selectedStar {
            VStack {
                Spacer()
                Text("\(star.artistName.uppercased()) · ALBUM \(star.sequence)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.74))
                    .overlay(Rectangle().stroke(.white.opacity(0.24), lineWidth: 0.5))
                    .accessibilityIdentifier("aeon.sky.star-selection")
            }
            .padding(.bottom, 24)
        }
    }
}

private struct SkyLabelOverlay: View {
    @ObservedObject var controller: SkySceneController
    let viewport: CGSize

    var body: some View {
        ZStack {
            ForEach(labels.prefix(80)) { label in
                Text(label.text)
                    .font(.system(size: label.isRegion ? 12 : 10, weight: .medium, design: .monospaced))
                    .tracking(label.isRegion ? 1.6 : 0.8)
                    .foregroundStyle(.white.opacity(label.isRegion ? 0.9 : 0.82))
                    .shadow(color: .black, radius: 3)
                    .position(label.position)
            }
        }
    }

    private var labels: [Label] {
        let camera = controller.camera
        let resolvedViewport = SkyViewport(size: viewport)
        let starByID = Dictionary(uniqueKeysWithValues: controller.catalogue.stars.map { ($0.albumID, $0) })
        if camera.tier == .galaxy || camera.tier == .region {
            return controller.catalogue.regions.compactMap { region in
                let points = controller.catalogue.stars.filter { $0.regionID == region.id }.map(\.coordinate)
                guard !points.isEmpty else { return nil }
                let center = SkyPoint(
                    x: Int32(points.map { Int64($0.x) }.reduce(0, +) / Int64(points.count)),
                    y: Int32(points.map { Int64($0.y) }.reduce(0, +) / Int64(points.count))
                )
                return Label(id: region.id, text: region.name.uppercased(), position: camera.screenPoint(for: center, viewport: resolvedViewport), isRegion: true)
            }.filter(visible)
        }
        return controller.catalogue.constellations.compactMap { constellation in
            let points = constellation.albumIDs.compactMap { starByID[$0]?.coordinate }
            guard !points.isEmpty else { return nil }
            let center = SkyPoint(
                x: Int32(points.map { Int64($0.x) }.reduce(0, +) / Int64(points.count)),
                y: Int32(points.map { Int64($0.y) }.reduce(0, +) / Int64(points.count))
            )
            return Label(id: constellation.id, text: constellation.artistName.uppercased(), position: camera.screenPoint(for: center, viewport: resolvedViewport), isRegion: false)
        }.filter(visible)
    }

    private func visible(_ label: Label) -> Bool {
        (-80...viewport.width + 80).contains(label.position.x) && (-80...viewport.height + 80).contains(label.position.y)
    }

    private struct Label: Identifiable {
        let id: String
        let text: String
        let position: CGPoint
        let isRegion: Bool
    }
}
