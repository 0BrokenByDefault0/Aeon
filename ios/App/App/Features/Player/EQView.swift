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
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    AeonLabel(text: "Equalizer")
                    Text("Ten bands, ±12 dB")
                        .font(AeonTheme.FontToken.ui(.caption))
                        .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
                }
                Spacer()
                Toggle(
                    "BYPASS",
                    isOn: Binding(
                        get: { !(playback.snapshot?.eqEnabled ?? false) },
                        set: { bypassed in playback.setEQ(enabled: !bypassed, bands: currentBands) }
                    )
                )
                .labelsHidden()
                .toggleStyle(AeonToggleStyle())
                .accessibilityLabel("Equalizer bypass")
                .accessibilityIdentifier("aeon.player.eq.bypass")
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: AeonTheme.Space.small)], spacing: AeonTheme.Space.small) {
                ForEach(Self.presets) { preset in
                    let selected = selectedPreset == preset.name
                    Button(preset.name) { select(preset) }
                        .buttonStyle(AeonButtonStyle(tier: selected ? .filled : .hairline))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("aeon.player.eq.preset.\(preset.name.lowercased().replacingOccurrences(of: " ", with: "-"))")
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: AeonTheme.Space.small) {
                    ForEach(Self.frequencies.indices, id: \.self) { index in
                        EQBandControl(
                            frequency: Self.frequencies[index],
                            gain: currentBands[index].gainDB,
                            onChange: { updateBand(index: index, gain: $0) }
                        )
                    }
                }
            }
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
        VStack(spacing: 5) {
            Text(db(gain))
                .font(AeonTheme.FontToken.metric(.caption2))
                .foregroundStyle(AeonTheme.ColorToken.boneSecondary)
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
                        .frame(width: 22, height: 6)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(frequency)) hertz gain")
        .accessibilityValue("\(db(gain)) decibels")
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
