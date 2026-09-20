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

    var body: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
            header
            presets
            bandEditor
        }
        .padding(.top, AeonTheme.Space.large)
        .overlay(alignment: .top) {
            Rectangle().fill(AeonTheme.ColorToken.rule).frame(height: AeonTheme.Stroke.hairline)
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
                Text("10 bands · scroll")
                    .font(AeonTheme.FontToken.metadata)
                    .foregroundStyle(AeonTheme.ColorToken.boneTertiary)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: AeonTheme.Space.small) {
                    ForEach(Self.frequencies.indices, id: \.self) { index in
                        EQBandControl(
                            frequency: Self.frequencies[index],
                            gain: currentBands[index].gainDB,
                            onChange: { updateBand(index: index, gain: $0) }
                        )
                    }
                }
                .padding(.vertical, AeonTheme.Space.small)
                .padding(.horizontal, 2)
            }
            .accessibilityIdentifier("aeon.player.eq.bands")
            .accessibilityHint("Swipe horizontally to reach all ten equalizer bands")
        }
    }

    private var currentBands: [EQBand] {
        guard let bands = playback.snapshot?.eqBands, bands.count == Self.frequencies.count else {
            return Self.frequencies.map { EQBand(frequency: $0, q: 1, gainDB: 0) }
        }
        return bands
    }

    private var selectedPreset: String? {
        let gains = currentBands.map(\.gainDB)
        return Self.presets.first { preset in
            zip(preset.gains, gains).allSatisfy { abs($0 - $1) < 0.001 }
        }?.name
    }

    private func select(_ preset: Preset) {
        let bands = zip(Self.frequencies, preset.gains).map { EQBand(frequency: $0, q: 1, gainDB: $1) }
        playback.setEQ(enabled: true, bands: bands)
    }

    private func updateBand(index: Int, gain: Double) {
        var bands = currentBands
        bands[index] = EQBand(frequency: bands[index].frequency, q: bands[index].q, gainDB: gain)
        playback.setEQ(enabled: playback.snapshot?.eqEnabled ?? true, bands: bands)
    }
}

private struct EQBandControl: View {
    let frequency: Double
    let gain: Double
    let onChange: (Double) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(db(gain))
                .font(AeonTheme.FontToken.metric(.caption2, weight: .medium))
                .foregroundStyle(AeonTheme.ColorToken.bone)
                .monospacedDigit()
            GeometryReader { geometry in
                let fraction = CGFloat((12 - min(12, max(-12, gain))) / 24)
                ZStack(alignment: .top) {
                    Rectangle()
                        .fill(AeonTheme.ColorToken.rule)
                        .frame(width: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Rectangle()
                        .fill(AeonTheme.ColorToken.bone)
                        .frame(width: 24, height: 6)
                        .offset(y: fraction * max(0, geometry.size.height - 6))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    let fraction = min(1, max(0, gesture.location.y / max(1, geometry.size.height)))
                    onChange((12 - Double(fraction) * 24).rounded())
                })
            }
            .frame(width: AeonTheme.Space.minimumTarget, height: 132)
            Text(frequencyLabel)
                .font(AeonTheme.FontToken.metric(.caption2))
                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(frequency)) hertz gain")
        .accessibilityValue("\(db(gain)) decibels")
        .accessibilityIdentifier("aeon.player.eq.band.\(Int(frequency))")
        .accessibilityAdjustableAction { direction in
            onChange(min(12, max(-12, gain + (direction == .increment ? 1 : -1))))
        }
    }

    private var frequencyLabel: String {
        frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
    }

    private func db(_ value: Double) -> String {
        value > 0 ? "+\(Int(value))" : "\(Int(value))"
    }
}
