import SwiftUI

enum NowPlayingSection: String, Hashable {
    case equalizer
    case spectrum
}

struct NowPlayingView: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject var spectrum: SpectrumAnalyzer
    let catalog: CatalogRepository
    let artworkStore: ArtworkStore
    let initialSection: NowPlayingSection?
    let reduceMotionOverride: Bool
    let close: () -> Void
    let locate: (String, Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.aeonArtworkTint) private var artworkTint
    @State private var queuePresented = false
    @State private var seekPreview: Double?

    var body: some View {
        AeonGlass {
            ScrollViewReader { proxy in
                ScrollView {
                    if let presentation = PlayerPresentation.resolve(
                    snapshot: playback.snapshot,
                    catalog: catalog,
                    artworkStore: artworkStore
                ), let snapshot = playback.snapshot {
                    VStack(spacing: AeonTheme.Space.section) {
                        heading(snapshot: snapshot)
                        artworkStage(presentation)
                        metadata(presentation: presentation, snapshot: snapshot)
                        seek(presentation: presentation, snapshot: snapshot)
                        transport(snapshot: snapshot)
                        queueControls(snapshot: snapshot)
                        volume(snapshot: snapshot)
                        secondary(presentation: presentation, snapshot: snapshot)
                        EQView(playback: playback).id(NowPlayingSection.equalizer)
                        spectrumSection.id(NowPlayingSection.spectrum)
                        }
                        .padding(.horizontal, AeonTheme.Space.edge)
                        .padding(.bottom, AeonTheme.Space.section)
                        .frame(maxWidth: 620)
                        .frame(maxWidth: .infinity)
                    } else {
                        AeonEmptyState(title: "Nothing in the player", detail: nil, actionTitle: nil, action: nil)
                            .frame(maxWidth: .infinity, minHeight: 420)
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    guard let initialSection else { return }
                    DispatchQueue.main.async { proxy.scrollTo(initialSection, anchor: .top) }
                }
            }
        }
        .background(AeonTheme.ColorToken.void.opacity(0.72).ignoresSafeArea())
        .sheet(isPresented: $queuePresented) {
            QueueView(playback: playback, catalog: catalog, close: { queuePresented = false })
        }
        .onAppear { spectrum.setReduceMotion(reduceMotion || reduceMotionOverride) }
        .onChange(of: reduceMotion) { spectrum.setReduceMotion($0 || reduceMotionOverride) }
    }

    private func heading(snapshot: PlaybackSnapshot) -> some View {
        HStack(spacing: AeonTheme.Space.medium) {
            if let index = snapshot.queueIndex {
                Text("\(index + 1) / \(snapshot.queue.count)")
                    .font(AeonTheme.FontToken.metric(.caption, weight: .medium))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .monospacedDigit()
            }
            AeonBreadcrumb(text: "Now Playing")
            Button(action: close) {
                Image(systemName: "xmark")
                    .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AeonTheme.ColorToken.bone)
            .accessibilityLabel("Close Now Playing")
            .accessibilityIdentifier("aeon.player.close")
        }
    }

    private func artworkStage(_ presentation: PlayerPresentation) -> some View {
        GeometryReader { geometry in
            let size = min(340, max(180, min(geometry.size.width - 50, geometry.size.height)))
            ZStack {
                RadialGradient(
                    colors: [(artworkTint ?? AeonTheme.ColorToken.silver).opacity(0.34), .clear],
                    center: .center,
                    startRadius: 5,
                    endRadius: size * 0.72
                )
                .frame(width: size * 1.38, height: size * 1.38)
                AeonGlass {
                    AeonArtwork(image: presentation.artwork, size: size)
                        .padding(AeonTheme.Space.medium)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 350)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Artwork for \(presentation.album.title)")
    }

    private func metadata(presentation: PlayerPresentation, snapshot: PlaybackSnapshot) -> some View {
        VStack(spacing: 6) {
            AeonDisplayText(presentation.track.title, size: 38, maximumLines: 2)
                .multilineTextAlignment(.center)
                .foregroundStyle(AeonTheme.ColorToken.bone)
            Text(presentation.artist)
                .font(AeonTheme.FontToken.ui(.title3, weight: .medium))
                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
            AeonLabel(text: snapshot.intent == .playing ? "Playing" : "In the player")
            if let failure = playback.failure, failure.recoverable {
                Button { playback.dismissFailure() } label: {
                    Text(failure.message)
                        .font(AeonTheme.FontToken.ui(.caption))
                        .foregroundStyle(AeonTheme.ColorToken.danger)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Dismiss")
                .accessibilityIdentifier("aeon.player.failure")
            }
        }
    }

    private func seek(presentation: PlayerPresentation, snapshot: PlaybackSnapshot) -> some View {
        let value = seekPreview ?? snapshot.position
        return VStack(spacing: 4) {
            AeonHorizontalRangeControl(
                value: value,
                range: 0...max(1, presentation.duration),
                label: "Seek",
                valueLabel: time(value),
                onChanged: { seekPreview = $0 },
                onEnded: {
                    seekPreview = nil
                    playback.seek(to: $0)
                }
            )
            HStack {
                Text(time(value))
                Spacer()
                Text("−" + time(max(0, presentation.duration - value)))
            }
            .font(AeonTheme.FontToken.metric(.caption2))
            .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
        }
    }

    private func transport(snapshot: PlaybackSnapshot) -> some View {
        HStack(spacing: 32) {
            transportButton("backward.end.fill", label: "Previous track", identifier: "aeon.player.previous", action: playback.previous)
            Button(action: playback.toggle) {
                Image(systemName: snapshot.intent == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(AeonTheme.ColorToken.void)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(AeonTheme.ColorToken.bone))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(snapshot.intent == .playing ? "Pause" : "Play")
            .accessibilityIdentifier("aeon.player.primary-toggle")
            transportButton("forward.end.fill", label: "Next track", identifier: "aeon.player.next-full", action: playback.next)
        }
    }

    private func queueControls(snapshot: PlaybackSnapshot) -> some View {
        HStack(spacing: AeonTheme.Space.small) {
            Button("SHUFFLE", action: playback.shuffleUpcoming)
                .buttonStyle(AeonButtonStyle(tier: .bare))
                .accessibilityIdentifier("aeon.player.shuffle")
            Button("REPEAT · \(snapshot.repeatMode.rawValue.uppercased())", action: playback.cycleRepeatMode)
                .buttonStyle(AeonButtonStyle(tier: snapshot.repeatMode == .off ? .bare : .hairline))
                .accessibilityValue(snapshot.repeatMode.rawValue)
                .accessibilityIdentifier("aeon.player.repeat")
            Button("UP NEXT") { queuePresented = true }
                .buttonStyle(AeonButtonStyle(tier: .bare))
                .accessibilityIdentifier("aeon.player.queue.open")
        }
    }

    private func volume(snapshot: PlaybackSnapshot) -> some View {
        HStack(spacing: AeonTheme.Space.medium) {
            Image(systemName: "speaker.fill").accessibilityHidden(true)
            AeonHorizontalRangeControl(
                value: snapshot.masterVolume,
                range: 0...1,
                label: "Volume",
                valueLabel: "\(Int(snapshot.masterVolume * 100)) percent",
                onChanged: { playback.setVolume(Float($0)) },
                onEnded: { _ in }
            )
            Image(systemName: "speaker.wave.2.fill").accessibilityHidden(true)
        }
        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
    }

    private func secondary(presentation: PlayerPresentation, snapshot: PlaybackSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
            Button("LOCATE") { locate(presentation.album.id, reduceMotion) }
                .buttonStyle(AeonButtonStyle(tier: .hairline))
                .accessibilityIdentifier("aeon.player.locate")
            if let source = sourceDescription(snapshot.sourceFormat), !source.isEmpty {
                detailLine(label: "SOURCE", value: source)
            }
            if let output = outputDescription(snapshot.outputFormat), !output.isEmpty {
                detailLine(label: "OUTPUT", value: output)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var spectrumSection: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
            AeonLabel(text: "Spectrum")
            AeonSegment(
                values: SpectrumMode.allCases,
                selection: Binding(get: { playback.spectrumMode }, set: playback.setSpectrumMode),
                label: { $0.rawValue }
            )
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(spectrum.bands.enumerated()), id: \.offset) { _, value in
                    Rectangle()
                        .fill(AeonTheme.ColorToken.bone)
                        .frame(maxWidth: .infinity)
                        .frame(height: reduceMotion ? 2 : max(2, CGFloat(value) * 86))
                }
            }
            .frame(height: 88, alignment: .bottom)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(reduceMotion ? "Spectrum still under Reduce Motion" : "Live audio spectrum")
            .accessibilityIdentifier("aeon.player.spectrum")
        }
    }

    private func transportButton(_ symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .medium))
                .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AeonTheme.ColorToken.bone)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func detailLine(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AeonTheme.Space.medium) {
            AeonLabel(text: label).frame(width: 64, alignment: .leading)
            Text(value)
                .font(AeonTheme.FontToken.metric(.caption))
                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
        }
    }

    private func sourceDescription(_ descriptor: SourceFormatDescriptor?) -> String? {
        guard let descriptor else { return nil }
        var values: [String] = []
        if let codec = descriptor.codec, !codec.isEmpty { values.append(codec.uppercased()) }
        if let rate = descriptor.sampleRate, rate > 0 { values.append(sampleRate(rate)) }
        if let depth = descriptor.bitDepth, depth > 0 { values.append("\(depth)-BIT") }
        if let channels = descriptor.channelCount, channels > 0 { values.append("\(channels) CH") }
        return values.joined(separator: " · ")
    }

    private func outputDescription(_ descriptor: OutputFormatDescriptor?) -> String? {
        guard let descriptor else { return nil }
        var values = [descriptor.route.name]
        if descriptor.sampleRate > 0 { values.append(sampleRate(descriptor.sampleRate)) }
        if descriptor.channelCount > 0 { values.append("\(descriptor.channelCount) CH") }
        return values.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func sampleRate(_ rate: Double) -> String {
        let khz = rate / 1_000
        return khz.rounded() == khz ? "\(Int(khz)) KHZ" : String(format: "%.1f KHZ", khz)
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private struct AeonHorizontalRangeControl: View {
    let value: Double
    let range: ClosedRange<Double>
    let label: String
    let valueLabel: String
    let onChanged: (Double) -> Void
    let onEnded: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let fraction = CGFloat((clampedValue - range.lowerBound) / max(0.000_001, range.upperBound - range.lowerBound))
            ZStack(alignment: .leading) {
                Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: 2)
                Rectangle().fill(AeonTheme.ColorToken.bone).frame(width: geometry.size.width * fraction, height: 2)
                Rectangle()
                    .fill(AeonTheme.ColorToken.bone)
                    .frame(width: 6, height: 22)
                    .offset(x: max(0, min(geometry.size.width - 6, geometry.size.width * fraction - 3)))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { onChanged(value(at: $0.location.x, width: geometry.size.width)) }
                    .onEnded { onEnded(value(at: $0.location.x, width: geometry.size.width)) }
            )
        }
        .frame(minHeight: AeonTheme.Space.minimumTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueLabel)
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            let adjusted = clampedValue + (direction == .increment ? step : -step)
            onEnded(min(range.upperBound, max(range.lowerBound, adjusted)))
        }
    }

    private var clampedValue: Double { min(range.upperBound, max(range.lowerBound, value)) }

    private func value(at x: CGFloat, width: CGFloat) -> Double {
        let fraction = min(1, max(0, Double(x / max(1, width))))
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }
}
