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
    let showAlbum: (String) -> Void
    let showArtist: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var queuePresented = false
    @State private var seekPreview: Double?
    @State private var requestedSection: NowPlayingSection?

    var body: some View {
        AeonGlass {
            VStack(spacing: 0) {
                heading(queuePosition: playback.snapshot?.queueIndex.map {
                    (index: $0, count: playback.snapshot?.queue.count ?? 0)
                })
                .padding(.horizontal, AeonTheme.Space.edge)
                .background(AeonTheme.ColorToken.void)

                Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)

                ScrollViewReader { proxy in
                    ScrollView {
                        if let presentation = PlayerPresentation.resolve(
                            snapshot: playback.snapshot,
                            catalog: catalog,
                            artworkStore: artworkStore
                        ), let snapshot = playback.snapshot {
                            VStack(spacing: AeonTheme.Space.section) {
                                VStack(spacing: AeonTheme.Space.large) {
                                    artworkStage(presentation)
                                    metadata(presentation: presentation)
                                    seek(presentation: presentation, snapshot: snapshot)
                                    transport(snapshot: snapshot)
                                }
                                queueControls(snapshot: snapshot)
                                volume(snapshot: snapshot)
                                secondary(presentation: presentation, snapshot: snapshot)
                                EQView(playback: playback).id(NowPlayingSection.equalizer)
                                spectrumSection.id(NowPlayingSection.spectrum)
                            }
                            .padding(.horizontal, AeonTheme.Space.edge)
                            .padding(.top, AeonTheme.Space.large)
                            .padding(.bottom, AeonTheme.Space.section)
                            .frame(maxWidth: 620)
                            .frame(maxWidth: .infinity)
                        } else {
                            VStack(spacing: AeonTheme.Space.section) {
                                AeonEmptyState(
                                    title: "Nothing in the player",
                                    detail: "Choose a track from your library and it will appear here.",
                                    actionTitle: "BACK TO AEON",
                                    action: close
                                )
                                .accessibilityIdentifier("aeon.player.empty")
                            }
                            .padding(.horizontal, AeonTheme.Space.edge)
                            .padding(.vertical, AeonTheme.Space.section)
                            .frame(maxWidth: 620, minHeight: 420)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .scrollIndicators(.hidden)
                    .accessibilityIdentifier("aeon.player.scroll")
                    .onChange(of: requestedSection) { section in
                        guard let section else { return }
                        proxy.scrollTo(section, anchor: .top)
                        requestedSection = nil
                    }
                    .onAppear {
                        guard let initialSection else { return }
                        DispatchQueue.main.async { proxy.scrollTo(initialSection, anchor: .top) }
                    }
                }
            }
        }
        .background(AeonTheme.ColorToken.void.ignoresSafeArea())
        .sheet(isPresented: $queuePresented) {
            QueueView(
                playback: playback,
                catalog: catalog,
                close: { queuePresented = false },
                showAlbum: showAlbum,
                showArtist: showArtist
            )
        }
        .onAppear { spectrum.setReduceMotion(effectiveReduceMotion) }
        .onChange(of: reduceMotion) { spectrum.setReduceMotion($0 || reduceMotionOverride || AeonTestOverrides.reduceMotion) }
    }

    private func heading(queuePosition: (index: Int, count: Int)?) -> some View {
        HStack(spacing: AeonTheme.Space.medium) {
            if let queuePosition {
                Text("\(queuePosition.index + 1) / \(queuePosition.count)")
                    .font(AeonTheme.FontToken.metric(.caption, weight: .medium))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .monospacedDigit()
            }
            AeonBreadcrumb(text: "Now Playing")
            Spacer(minLength: 0)
            Button("EQ") { requestedSection = .equalizer }
                .font(AeonTheme.FontToken.metric(.caption))
                .frame(width: 44, height: 44)
                .buttonStyle(.plain)
                .accessibilityLabel("Show equalizer")
                .accessibilityIdentifier("aeon.player.eq.open")
            Button(action: close) {
                AeonGlyph(kind: .close)
                    .frame(width: AeonTheme.Space.minimumTarget, height: AeonTheme.Space.minimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AeonTheme.ColorToken.textPrimary)
            .accessibilityLabel("Close Now Playing")
            .accessibilityIdentifier("aeon.player.close")
        }
    }

    private func artworkStage(_ presentation: PlayerPresentation) -> some View {
        GeometryReader { geometry in
            let maximum: CGFloat = dynamicTypeSize.isAccessibilitySize ? 220 : 280
            let size = min(maximum, max(176, geometry.size.width - 72))
            ZStack {
                // The record on the stage is marked by the same reticle that marks every
                // other current choice. A circle drawn around square artwork read as a
                // leftover from the pre-square geometry.
                AeonReticleMark()
                    .stroke(AeonOrbit.ink.opacity(0.34), style: AeonOrbit.line)
                    .frame(width: size + 40, height: size + 36)
                AeonArtwork(image: presentation.artwork, size: size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 246 : 306)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Artwork for \(presentation.album.title)")
    }

    private func metadata(presentation: PlayerPresentation) -> some View {
        VStack(spacing: AeonTheme.Space.small) {
            Text(playback.snapshot?.intent == .playing ? "PLAYING" : "PAUSED")
                .font(AeonTheme.FontToken.metric(.caption2))
                .tracking(1.4)
                .foregroundStyle(AeonOrbit.secondary)
            AeonDisplayText(presentation.track.title, size: 36, maximumLines: 2)
                .multilineTextAlignment(.center)
                .foregroundStyle(AeonOrbit.title)
            // Artist and album were the same size, weight and family, so the three
            // centred lines read as one undifferentiated block. Artist now leads.
            Text(presentation.artist)
                .font(AeonTheme.FontToken.ui(.headline, weight: .medium))
                .foregroundStyle(AeonTheme.ColorToken.ivorySecondary)
                .multilineTextAlignment(.center)
            Text(presentation.album.title)
                .font(AeonTheme.FontToken.secondary)
                .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                .multilineTextAlignment(.center)
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
        return VStack(spacing: AeonTheme.Space.xSmall) {
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
        HStack(spacing: 34) {
            transportButton(.previous, label: "Previous track", identifier: "aeon.player.previous", action: playback.previous)
            Button {
                AeonFeedback.transport()
                playback.toggle()
            } label: {
                ZStack {
                    AeonReticleField().fill(AeonOrbit.activeFill)
                    AeonReticleMark().stroke(AeonOrbit.ink, style: AeonOrbit.line)
                    AeonGlyph(kind: snapshot.intent == .playing ? .pause : .play)
                        .frame(width: 30, height: 30)
                }
                .frame(width: 72, height: 72)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(snapshot.intent == .playing ? "Pause" : "Play")
            .accessibilityIdentifier("aeon.player.primary-toggle")
            transportButton(.next, label: "Next track", identifier: "aeon.player.next-full", action: playback.next)
        }
    }

    private func queueControls(snapshot: PlaybackSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AeonTheme.Space.small) { queueControlContent(snapshot: snapshot) }
            VStack(spacing: AeonTheme.Space.xSmall) { queueControlContent(snapshot: snapshot) }
        }
    }

    @ViewBuilder
    private func queueControlContent(snapshot: PlaybackSnapshot) -> some View {
        secondaryTransportButton(
            glyph: .shuffle, title: "Shuffle", active: false,
            accessibilityLabel: "Shuffle upcoming tracks",
            identifier: "aeon.player.shuffle", action: playback.shuffleUpcoming
        )
        secondaryTransportButton(
            glyph: .repeatTrack,
            title: snapshot.repeatMode == .off ? "Repeat" : (snapshot.repeatMode == .one ? "Repeat one" : "Repeat all"),
            active: snapshot.repeatMode != .off,
            accessibilityLabel: "Repeat mode",
            accessibilityValue: snapshot.repeatMode.rawValue,
            identifier: "aeon.player.repeat", action: playback.cycleRepeatMode
        )
        secondaryTransportButton(
            glyph: .grip, title: "Up next", active: false,
            accessibilityLabel: "Open Up Next queue",
            identifier: "aeon.player.queue.open", action: { queuePresented = true }
        )
    }

    private func volume(snapshot: PlaybackSnapshot) -> some View {
        HStack(spacing: AeonTheme.Space.medium) {
            AeonGlyph(kind: .volumeLow).accessibilityHidden(true)
            AeonHorizontalRangeControl(
                value: snapshot.masterVolume,
                range: 0...1,
                label: "Volume",
                valueLabel: "\(Int(snapshot.masterVolume * 100)) percent",
                onChanged: { playback.setVolume(Float($0)) },
                onEnded: { _ in }
            )
            AeonGlyph(kind: .volumeHigh).accessibilityHidden(true)
        }
        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
    }

    private func secondary(presentation: PlayerPresentation, snapshot: PlaybackSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.regular) {
            Button { locate(presentation.album.id, effectiveReduceMotion) } label: {
                HStack(spacing: AeonTheme.Space.medium) {
                    AeonGlyph(kind: .sky)
                        .foregroundStyle(AeonTheme.ColorToken.ivorySecondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: AeonTheme.Space.xSmall) {
                        Text("Locate in the Sky")
                            .font(AeonTheme.FontToken.ui(.body, weight: .medium))
                            .foregroundStyle(AeonTheme.ColorToken.textPrimary)
                        Text("Return to this album’s place in your collection.")
                            .font(AeonTheme.FontToken.ui(.caption))
                            .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    }
                    Spacer()
                    AeonGlyph(kind: .disclosure)
                        .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                }
                .padding(.vertical, AeonTheme.Space.small)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("aeon.player.locate")

            Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)

            if let source = sourceDescription(snapshot.sourceFormat), !source.isEmpty {
                detailLine(label: "SOURCE", value: source)
            }
            if let output = outputDescription(snapshot.outputFormat), !output.isEmpty {
                detailLine(label: "OUTPUT", value: output)
            }
            if let loudness = replayGainDescription(snapshot), !loudness.isEmpty {
                detailLine(label: "LEVEL", value: loudness)
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
                        .frame(height: effectiveReduceMotion ? 2 : max(2, CGFloat(value) * 86))
                }
            }
            .frame(height: 88, alignment: .bottom)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(effectiveReduceMotion ? "Spectrum still under Reduce Motion" : "Live audio spectrum")
            .accessibilityIdentifier("aeon.player.spectrum")
        }
    }

    private var effectiveReduceMotion: Bool {
        reduceMotion || reduceMotionOverride || AeonTestOverrides.reduceMotion
    }

    private func transportButton(_ glyph: AeonGlyphKind, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button {
            AeonFeedback.transport()
            action()
        } label: {
            AeonGlyph(kind: glyph)
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AeonTheme.ColorToken.textPrimary)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func secondaryTransportButton(
        glyph: AeonGlyphKind,
        title: String,
        active: Bool,
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            AeonFeedback.activated()
            action()
        } label: {
            HStack(spacing: AeonTheme.Space.small) {
                AeonGlyph(kind: glyph).frame(width: 22, height: 22)
                Text(title).font(AeonTheme.FontToken.utility).lineLimit(1)
            }
            .foregroundStyle(active ? AeonOrbit.ink : AeonOrbit.secondary)
            .padding(.horizontal, AeonTheme.Space.small)
            .frame(maxWidth: .infinity, minHeight: AeonTheme.Space.minimumTarget)
            .background(active ? AeonOrbit.activeFill : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityAddTraits(active ? .isSelected : [])
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

    private func replayGainDescription(_ snapshot: PlaybackSnapshot) -> String? {
        let mode = snapshot.replayGainMode
        guard mode != .off else { return nil }
        let gain = mode == .track
            ? snapshot.sourceFormat?.replayGain?.trackGainDB
            : snapshot.sourceFormat?.replayGain?.albumGainDB
        var values = [mode.rawValue.uppercased()]
        if let gain { values.append(String(format: "%+.1f dB", gain)) }
        if snapshot.replayGainPreampDB != 0 {
            values.append(String(format: "%+.1f dB PREAMP", snapshot.replayGainPreampDB))
        }
        return values.joined(separator: " · ")
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
                Rectangle().fill(AeonTheme.ColorToken.bone).frame(width: geometry.size.width * fraction, height: 3)
                Circle()
                    .fill(AeonTheme.ColorToken.bone)
                    .frame(width: 12, height: 12)
                    .offset(x: max(0, min(geometry.size.width - 12, geometry.size.width * fraction - 6)))
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
