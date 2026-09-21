import SwiftUI

struct EQView: View {
    static let frequencies = TonalPreset.frequencies
    static let presets = TonalPreset.factory

    @ObservedObject var playback: PlaybackController
    @State private var activeBand: Int?
    @State private var draftBands: [EQBand]?
    @State private var manualEdit = false
    @State private var inspectedBand = 0
    @State private var presetName = ""
    @State private var showInspector = false

    var body: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
            header
            presets
            bandEditor
            if showInspector {
                EQBandInspector(band: currentBands[inspectedBand]) { band in
                    var bands = currentBands; bands[inspectedBand] = band
                    draftBands = bands; manualEdit = true
                    playback.setEQ(enabled: playback.snapshot?.eqEnabled ?? true, bands: bands)
                }.id(currentBands[inspectedBand].id)
            }
            EQResponseView(bands: currentBands, rate: playback.snapshot?.outputFormat?.processingSampleRate ?? 48_000)
                .frame(height: 84)
            savedPresets
            DeviceCorrectionView(playback: playback)
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
            Text("Ten parametric bands · ±12 dB")
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
                    case "Bass lift": return "BASS +"
                    case "Bass reduction": return "BASS −"
                    case "Less low-mid": return "LOW MID"
                    case "Gentle presence": return "PRESENCE"
                    case "Softer treble": return "TREBLE"
                    default: return name.uppercased()
                    }
                },
                identifier: { "aeon.player.eq.preset.\($0.lowercased().replacingOccurrences(of: " ", with: "-"))" },
                spokenLabel: { $0 }
            )
            .accessibilityIdentifier("aeon.player.eq.presets")
            Text(Self.presets.first { $0.name == selectedPreset }?.detail ?? "Modified / custom curve")
                .font(AeonTheme.FontToken.ui(.caption)).foregroundStyle(AeonOrbit.secondary)
        }
    }

    private var bandEditor: some View {
        VStack(alignment: .leading, spacing: AeonTheme.Space.small) {
            HStack(alignment: .firstTextBaseline) {
                AeonLabel(text: "Bands")
                Spacer()
                if let activeBand {
                    Text("\(frequencyLabel(currentBands[activeBand].frequency))  \(db(currentBands[activeBand].gainDB)) dB")
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
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Self.frequencies.indices, id: \.self) { index in
                                EQBandControl(
                                    frequency: currentBands[index].frequency,
                                    gain: currentBands[index].gainDB,
                                    plotHeight: 166,
                                    active: activeBand == index,
                                    onTouch: { activeBand = index; inspectedBand = index },
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
            HStack {
                Button(showInspector ? "CLOSE BAND EDITOR" : "EDIT BAND \(inspectedBand + 1)") { showInspector.toggle() }
                Spacer()
                Menu("BAND \(inspectedBand + 1)") {
                    ForEach(0..<10, id: \.self) { index in
                        Button("Band \(index+1) · \(frequencyLabel(currentBands[index].frequency)) Hz") { inspectedBand = index; showInspector = true }
                    }
                }
            }.font(AeonTheme.FontToken.metric(.caption2)).foregroundStyle(AeonOrbit.ink)
        }
    }

    private var currentBands: [EQBand] {
        if let draftBands, draftBands.count == Self.frequencies.count { return draftBands }
        guard let bands = playback.snapshot?.eqBands, bands.count == Self.frequencies.count else {
            return TonalPreset.flat
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
                pathRow("Device correction", state?.dsp.activeCorrection?.name ?? "Off")
                pathRow("Reference bypass", state?.dsp.referenceBypass == true ? "On · intentional DSP off" : "Off")
                let headroom = output?.effectivePreampDB ?? 0
                pathRow("Effective preamp", "\(db(headroom)) dB")
                pathRow("Output protection", state?.dsp.referenceBypass == true ? "Bypassed" : "On · −1 dBFS sample peak")
                pathRow("DSP latency", String(format: "%.2f ms", (output?.dspLatency ?? 0) * 1000))
                pathRow("Overload samples", "\(output?.overloadCount ?? 0)")
                if let count = output?.unavailableFilters, count > 0 { Text("\(count) requested filters exceed this route’s Nyquist limit and are temporarily bypassed.").foregroundStyle(.orange) }
                Text("Sample-peak protection is not true-peak protection. Route conversion can change reconstructed peaks. Reference bypass keeps the 128-frame DSP delay. DAC resolution and Bluetooth codec are not exposed.")
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
        return Self.presets.first { $0.bands == currentBands }?.name
    }

    private func select(_ preset: TonalPreset) {
        let bands = preset.bands
        manualEdit = false; draftBands = bands
        var settings = playback.snapshot?.dsp ?? .init(); settings.presetID = preset.id
        playback.setDSP(settings)
        playback.setEQ(enabled: true, bands: bands)
    }

    private var savedPresets: some View {
        DisclosureGroup("Saved curves") {
            VStack(alignment: .leading, spacing: 10) {
                Menu("CHOOSE SAVED CURVE") {
                    ForEach(playback.snapshot?.dsp.savedPresets ?? []) { preset in Button(preset.name) { select(preset) } }
                }
                TextField("Curve name", text: $presetName).textFieldStyle(.roundedBorder)
                HStack {
                    Button("SAVE COPY") {
                        var settings = playback.snapshot?.dsp ?? .init()
                        let preset = TonalPreset(name: presetName, detail: "Owner curve", bands: currentBands)
                        settings.savedPresets.append(preset); settings.presetID = preset.id
                        playback.setDSP(settings)
                    }.disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("RENAME") {
                        var settings = playback.snapshot?.dsp ?? .init()
                        if let index = settings.savedPresets.firstIndex(where: { $0.id == settings.presetID }) {
                            settings.savedPresets[index].name = presetName; playback.setDSP(settings)
                        }
                    }.disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("RESET") { select(Self.presets[0]) }
                }.font(AeonTheme.FontToken.metric(.caption2))
            }.padding(.top, 8)
        }.tint(AeonOrbit.ink).foregroundStyle(AeonOrbit.ink)
    }

    private func updateBand(index: Int, gain: Double) {
        var bands = currentBands
        bands[index].gainDB = min(12, max(-12, gain))
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
