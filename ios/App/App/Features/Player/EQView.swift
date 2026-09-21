import SwiftUI

struct EQView: View {
    struct Preset: Identifiable {
        let name: String
        let gains: [Double]
        var id: String { name }
    }

    static let frequencies: [Double] = [31, 62, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let presets: [Preset] = [
        Preset(name: "FLAT", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        Preset(name: "BASS RITUAL", gains: [9, 8, 6, 3, 0, -1, 0, 0, 1, 2]),
        Preset(name: "VOCAL CULT", gains: [-2, -1, 0, 2, 4, 5, 4, 2, 0, -1]),
        Preset(name: "AIRWAVE", gains: [0, 0, 0, 0, 0, 1, 2, 4, 6, 7]),
        Preset(name: "TUNNEL", gains: [5, 4, 1, -3, -5, -5, -3, 0, 3, 4])
    ]

    @ObservedObject var playback: PlaybackController
    @State private var activeBand: Int?
    @State private var draftBands: [EQBand]?
    @State private var manualEdit = false

    var body: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
            header
            presets
            bandEditor
            audioPath
        }
        .padding(.top, AeonTheme.Space.large)
        .overlay(alignment: .top) {
            Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
        }
        .onChange(of: playback.snapshot?.eqBands) { bands in
            if activeBand == nil { draftBands = bands }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AeonTheme.Space.medium) {
                headerCopy
                Spacer()
                enabledToggle
            }
            VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
                headerCopy
                enabledToggle
            }
        }
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 4) {
            AeonLabel(text: "Equalizer")
            Text("Ten bands · ±12 dB")
                .font(AeonTheme.FontToken.secondary)
                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
        }
    }

    private var enabledToggle: some View {
        Toggle(
            "Equalizer enabled",
            isOn: Binding(
                get: { playback.snapshot?.eqEnabled ?? false },
                set: { enabled in playback.setEQ(enabled: enabled, bands: currentBands) }
            )
        )
        .toggleStyle(AeonToggleStyle(showsLabel: false))
        .accessibilityLabel("Equalizer enabled")
        .accessibilityIdentifier("aeon.player.eq.bypass")
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
            AeonLabel(text: "Presets")
            AeonSegment(
                values: Self.presets.map(\.name),
                selection: Binding(
                    get: { selectedPreset ?? "" },
                    set: { name in
                        guard let preset = Self.presets.first(where: { $0.name == name }) else { return }
                        select(preset)
                    }
                ),
                label: { name in
                    switch name {
                    case "BASS RITUAL": return "BASS"
                    case "VOCAL CULT": return "VOICE"
                    case "AIRWAVE": return "AIR"
                    default: return name
                    }
                },
                identifier: { "aeon.player.eq.preset.\($0.lowercased().replacingOccurrences(of: " ", with: "-"))" },
                spokenLabel: { $0 }
            )
            .accessibilityIdentifier("aeon.player.eq.presets")
        }
    }

    private var bandEditor: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
            HStack(alignment: .firstTextBaseline) {
                AeonLabel(text: "Bands")
                Spacer()
                if let activeBand {
                    Text("\(frequencyLabel(Self.frequencies[activeBand]))  \(db(currentBands[activeBand].gainDB)) dB")
                        .font(AeonTheme.FontToken.metric(.caption, weight: .semibold))
                        .foregroundStyle(AeonTheme.ColorToken.bone)
                        .monospacedDigit()
                } else {
                    Text(manualEdit ? "CUSTOM" : "+12 / 0 / −12 dB")
                        .font(AeonTheme.FontToken.metric(.caption2))
                        .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                }
            }
            HStack(alignment: .top, spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Text("+12").offset(y: -5)
                    Text("0").offset(y: 78)
                    Text("−12").offset(y: 161)
                }
                .font(AeonTheme.FontToken.metric(.caption2))
                .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
                .frame(width: 24, height: 176, alignment: .topTrailing)
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            Rectangle().fill(AeonTheme.ColorToken.rule.opacity(0.55)).frame(height: 1)
                            Spacer()
                            Rectangle().fill(AeonTheme.ColorToken.boneTertiary.opacity(0.72)).frame(height: 1)
                            Spacer()
                            Rectangle().fill(AeonTheme.ColorToken.rule.opacity(0.55)).frame(height: 1)
                        }
                        .frame(height: 166)
                        Path { path in
                            for index in Self.frequencies.indices {
                                let point = CGPoint(x: geometry.size.width * (CGFloat(index) + 0.5) / 10,
                                                    y: CGFloat(12 - currentBands[index].gainDB) / 24 * 160 + 3)
                                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                            }
                        }
                        .stroke(AeonOrbit.ink.opacity(0.30), lineWidth: 1)
                        .allowsHitTesting(false)
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Self.frequencies.indices, id: \.self) { index in
                                EQBandControl(
                                    frequency: Self.frequencies[index],
                                    gain: currentBands[index].gainDB,
                                    plotHeight: 166,
                                    active: activeBand == index,
                                    onTouch: { activeBand = index },
                                    onEnd: { activeBand = nil },
                                    onChange: { updateBand(index: index, gain: $0) }
                                )
                                .frame(width: geometry.size.width / CGFloat(Self.frequencies.count))
                            }
                        }
                    }
                }
                .frame(height: 190)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("aeon.player.eq.bands")
                .accessibilityHint("All ten equalizer bands are visible and individually adjustable")
            }
        }
    }

    private var currentBands: [EQBand] {
        if let draftBands, draftBands.count == Self.frequencies.count { return draftBands }
        guard let bands = playback.snapshot?.eqBands, bands.count == Self.frequencies.count else {
            return Self.frequencies.map { EQBand(frequency: $0, q: 1, gainDB: 0) }
        }
        return bands
    }

    private var audioPath: some View {
        DisclosureGroup("Audio path") {
            VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
                let state = playback.snapshot
                let source = state?.sourceFormat
                let output = state?.outputFormat
                pathRow("Source", [source?.codec, source?.container].compactMap { $0 }.joined(separator: " / "))
                pathRow("Source rate", rateLabel(source?.sampleRate))
                pathRow("Source precision", sourceBitDepth(source))
                pathRow("Processing rate", rateLabel(output?.processingSampleRate))
                pathRow("Output rate", rateLabel(output?.route.sampleRate))
                pathRow("Route", output?.route.name ?? "Unknown")
                pathRow("User EQ", state?.eqEnabled == true ? "On" : "Bypassed")
                pathRow("Normalization", state?.replayGainMode.spokenLabel ?? "Off")
                if state?.replayGainMode != .off, let preamp = state?.replayGainPreampDB {
                    pathRow("ReplayGain preamp", "\(db(preamp)) dB · metadata-dependent")
                }
                let headroom = state?.eqEnabled == true ? AudioEngineGraph.headroomDB(for: state?.eqBands ?? []) : 0
                pathRow("EQ preamp", "\(db(headroom)) dB")
                pathRow("Output protection", "No validated limiter")
                Text("EQ preamp is a headroom estimate, not peak protection. Output rate describes the active audio path; DAC resolution and Bluetooth codec are not exposed here.")
                    .font(AeonTheme.FontToken.ui(.caption))
                    .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, AeonTheme.Space.small)
        }
        .font(AeonTheme.FontToken.ui(.callout))
        .foregroundStyle(AeonTheme.ColorToken.bone)
        .tint(AeonOrbit.ink)
        .accessibilityIdentifier("aeon.player.audio-path")
    }

    private func pathRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(AeonTheme.ColorToken.boneSecondary)
            Spacer(minLength: 16)
            Text(value.isEmpty ? "Unknown" : value).multilineTextAlignment(.trailing)
        }
        .font(AeonTheme.FontToken.ui(.caption))
        .accessibilityElement(children: .combine)
    }

    private func rateLabel(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, rate > 0 else { return "Unknown" }
        return String(format: "%.1f kHz", rate / 1_000)
    }

    private func sourceBitDepth(_ source: SourceFormatDescriptor?) -> String {
        guard let codec = source?.codec,
              codec.hasPrefix("pcm") || ["alac", "flac"].contains(codec),
              let depth = source?.bitDepth, depth > 0 else { return "Unknown / not applicable" }
        return "\(depth)-bit"
    }

    private var selectedPreset: String? {
        guard !manualEdit else { return nil }
        let gains = currentBands.map(\.gainDB)
        return Self.presets.first { preset in
            zip(preset.gains, gains).allSatisfy { abs($0 - $1) < 0.001 }
        }?.name
    }

    private func select(_ preset: Preset) {
        let bands = zip(Self.frequencies, preset.gains).map { EQBand(frequency: $0, q: 1, gainDB: $1) }
        manualEdit = false
        draftBands = bands
        playback.setEQ(enabled: true, bands: bands)
    }

    private func updateBand(index: Int, gain: Double) {
        var bands = currentBands
        bands[index] = EQBand(frequency: bands[index].frequency, q: bands[index].q, gainDB: min(12, max(-12, gain)))
        manualEdit = true
        draftBands = bands
        playback.setEQ(enabled: playback.snapshot?.eqEnabled ?? true, bands: bands)
    }

    private func frequencyLabel(_ frequency: Double) -> String {
        frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
    }

    private func db(_ value: Double) -> String {
        let rendered = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return value > 0 ? "+\(rendered)" : rendered
    }
}

private struct EQBandControl: View {
    let frequency: Double
    let gain: Double
    let plotHeight: CGFloat
    let active: Bool
    let onTouch: () -> Void
    let onEnd: () -> Void
    let onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let fraction = CGFloat((12 - min(12, max(-12, gain))) / 24)
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(AeonTheme.ColorToken.rule)
                        .frame(width: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle()
                        .fill(active ? AeonOrbit.ink : AeonTheme.ColorToken.bone)
                        .frame(width: min(active ? 22 : 18, max(10, geometry.size.width - 6)), height: active ? 7 : 5)
                        .offset(y: fraction * max(0, geometry.size.height - 6))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onTouch()
                        let fraction = min(1, max(0, gesture.location.y / max(1, geometry.size.height)))
                        onChange(12 - Double(fraction) * 24)
                    }
                    .onEnded { _ in onEnd() })
            }
            .frame(maxWidth: .infinity, minHeight: plotHeight, maxHeight: plotHeight)
            Text(frequencyLabel)
                .font(AeonTheme.FontToken.metric(.caption2))
                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(frequency)) hertz gain")
        .accessibilityValue("\(db(gain)) decibels")
        .accessibilityIdentifier("aeon.player.eq.band.\(Int(frequency))")
        .accessibilityAdjustableAction { direction in
            onTouch()
            onChange(min(12, max(-12, gain + (direction == .increment ? 1 : -1))))
            onEnd()
        }
    }

    private var frequencyLabel: String {
        frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
    }

    private func db(_ value: Double) -> String {
        let rendered = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return value > 0 ? "+\(rendered)" : rendered
    }
}
