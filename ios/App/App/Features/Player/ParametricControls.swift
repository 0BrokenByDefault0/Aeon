import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct EQBandInspector: View {
    let band: EQBand
    let apply: (EQBand) -> Void
    @State private var frequency = ""
    @State private var gain = ""
    @State private var q = ""
    @State private var type = EQFilterType.bell
    @State private var enabled = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Filter", selection: $type) { ForEach(EQFilterType.allCases) { Text($0.title).tag($0) } }.tint(AeonOrbit.ink)
            HStack {
                field("Hz", text: $frequency)
                field("Gain dB", text: $gain).disabled(type == .highPass || type == .lowPass)
                field("Q", text: $q)
            }
            Toggle("Band enabled", isOn: $enabled).toggleStyle(AeonToggleStyle())
            if band.version == 1 { Text("Saved legacy width retained. APPLY converts this band to the displayed digital Q.").font(.caption) }
            HStack {
                Button("APPLY") {
                    var edited = band
                    edited.frequency = Double(frequency) ?? .nan; edited.gainDB = (type == .highPass || type == .lowPass) ? 0 : Double(gain) ?? .nan; edited.q = Double(q) ?? .nan
                    edited.type = type; edited.enabled = enabled; edited.version = 2
                    do { try ParametricDSP.validate([edited]); error = nil; apply(edited) }
                    catch { self.error = error.localizedDescription }
                }
                Spacer()
                Button("RESET BAND") { var edited = band; edited.gainDB = 0; edited.q = 0.707; edited.enabled = true; edited.type = .bell; edited.version = 2; apply(edited); load(edited) }
            }.font(AeonTheme.FontToken.metric(.caption))
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            Text("Q controls bell width, cut resonance or shelf resonance. Cut filters are second-order, 12 dB/octave.")
                .font(AeonTheme.FontToken.ui(.caption)).foregroundStyle(AeonOrbit.secondary)
        }.foregroundStyle(AeonOrbit.ink).onAppear { load(band) }.onChange(of: band) { load($0) }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading) { Text(title).font(.caption); TextField(title, text: text).keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder) }
    }
    private func load(_ band: EQBand) {
        frequency = String(format: "%.1f", band.frequency); gain = String(format: "%.2f", band.gainDB); q = String(format: "%.3f", band.q)
        type = band.type; enabled = band.enabled
    }
}

struct EQResponseView: View {
    let bands: [EQBand]
    let rate: Double
    var body: some View {
        Canvas { context, size in
            var zero = Path(); zero.move(to: CGPoint(x: 0, y: size.height/2)); zero.addLine(to: CGPoint(x: size.width, y: size.height/2))
            context.stroke(zero, with: .color(.white.opacity(0.2)), lineWidth: 1)
            let filters = bands.compactMap { ParametricDSP.filter($0, rate: rate) }
            var response = Path()
            for i in 0...240 {
                let f = 20 * pow(min(20000, rate*0.499)/20, Double(i)/240)
                let db = filters.reduce(0) { $0 + $1.responseDB(f, rate: rate) }
                let point = CGPoint(x: size.width*CGFloat(i)/240, y: size.height*CGFloat(0.5-min(24,max(-24,db))/48))
                if i == 0 { response.move(to: point) } else { response.addLine(to: point) }
            }
            context.stroke(response, with: .color(AeonOrbit.ink), lineWidth: 1.5)
        }.accessibilityLabel("Calculated filter response, 20 hertz to Nyquist or 20 kilohertz, plus or minus 24 decibels")
    }
}

struct DeviceCorrectionView: View {
    @ObservedObject var playback: PlaybackController
    @State private var importing = false
    @State private var pending: CorrectionProfile?
    @State private var message: String?
    @State private var kind = CorrectionProfile.Kind.headphones
    @State private var choosingProfile = false
    @State private var profileName = ""
    private var settings: DSPSettings { playback.snapshot?.dsp ?? .init() }
    private var rate: Double { playback.snapshot?.outputFormat?.processingSampleRate ?? 48_000 }
    var body: some View {
        DisclosureGroup("Device correction & gain") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Device correction", isOn: Binding(get: { settings.correctionEnabled }, set: { value in edit { $0.correctionEnabled = value } }))
                    .toggleStyle(AeonToggleStyle())
                    .disabled(settings.correction == nil || settings.referenceBypass)
                    .accessibilityIdentifier("aeon.correction.enabled")
                Text(settings.correction?.name ?? "No profile selected").font(AeonTheme.FontToken.ui(.callout))
                if settings.referenceBypass {
                    Text("Reference bypass is on. Turn it off below to hear device correction.").font(.caption)
                } else if settings.correction == nil {
                    Text("Choose your exact headphone model or import a profile before enabling correction.")
                        .font(.caption).accessibilityIdentifier("aeon.correction.choose-first")
                }
                Button("CHOOSE PROFILE") { choosingProfile = true }
                    .accessibilityIdentifier("aeon.correction.choose")
                Picker("Import purpose", selection: $kind) {
                    Text("Headphones").tag(CorrectionProfile.Kind.headphones)
                    Text("Speaker measurement").tag(CorrectionProfile.Kind.speakerMeasurement)
                    Text("Speaker tonal").tag(CorrectionProfile.Kind.speakerTonal)
                }
                Button("IMPORT PARAMETRIC PROFILE") { importing = true }
                Text("AutoEq / Equalizer APO text: Preamp, ON/OFF PK, LS, HS, HP or LP, Fc in Hz, Gain in dB and Q. Up to ten filters, 64 KiB. Unmatched routes have no correction. Wired/USB devices require manual choice; Bluetooth/AirPlay endpoints can be explicitly bound.")
                    .font(AeonTheme.FontToken.ui(.caption)).foregroundStyle(AeonOrbit.secondary)
                if let profile = pending {
                    Text(profile.name).font(.headline)
                    Text(profile.provenance).font(.caption)
                    EQResponseView(bands: profile.bands, rate: rate).frame(height: 80)
                    Text("\(profile.bands.count) filters · recommended \(profile.preampDB, specifier: "%.1f") dB · combined preamp \(previewPreamp(profile), specifier: "%.1f") dB")
                        .font(.caption)
                    if profile.bands.contains(where: { $0.enabled && $0.frequency >= rate*0.499 }) {
                        Text("This route cannot represent every requested filter. Choose a higher-rate route before applying this profile.").font(.caption).foregroundStyle(.orange)
                    } else {
                        Button("APPLY TO CURRENT ROUTE") {
                            edit { state in
                                if !state.profiles.contains(where: { $0.id == profile.id }) { state.profiles.append(profile) }
                                state.correctionID = profile.id; state.correctionEnabled = true
                            }; pending = nil
                        }
                        .accessibilityIdentifier("aeon.correction.apply")
                    }
                    Button("CANCEL PREVIEW") { pending = nil }
                }
                if let route = playback.snapshot?.outputFormat?.route,
                   [.bluetooth, .airPlay].contains(route.kind), let routeID = route.persistentID, !routeID.isEmpty {
                    Toggle("Remember for this endpoint", isOn: Binding(
                        get: { settings.correctionID != nil && settings.routeBindings[routeID] == settings.correctionID },
                        set: { enabled in edit { if enabled { $0.routeBindings[routeID] = $0.correctionID } else { $0.routeBindings.removeValue(forKey: routeID) } } }))
                        .toggleStyle(AeonToggleStyle())
                }
                TextField("New tonal profile name", text: $profileName).textFieldStyle(.roundedBorder)
                Button("SAVE USER CURVE AS TONAL PROFILE") {
                    let bands = (playback.snapshot?.eqBands ?? TonalPreset.flat)
                    guard bands.allSatisfy({ $0.version == 2 }) else { message = "Reset or explicitly edit legacy bands before saving a new device profile."; return }
                    pending = CorrectionProfile(name: profileName, kind: kind == .headphones ? .headphones : .speakerTonal,
                        preampDB: 0, bands: bands, provenance: "Owner-created tonal profile. Not a measured correction.")
                }.disabled(profileName.trimmingCharacters(in: .whitespaces).isEmpty)
                if let profile = settings.correction {
                    if let entry = CorrectionCatalog.profiles.first(where: { $0.id == profile.id }) {
                        correctionCredit(entry)
                    }
                    DisclosureGroup("Correction filters") {
                        ForEach(Array(profile.bands.enumerated()), id: \.element.id) { index, band in
                            Text("\(index+1) · \(band.enabled ? "On" : "Off") · \(band.type.title) · \(band.frequency, specifier: "%.1f") Hz · \(band.gainDB, specifier: "%.1f") dB · Q \(band.q, specifier: "%.2f")").font(.caption)
                        }
                    }
                }
                Text("Final trim \(settings.trimDB, specifier: "%.1f") dB").font(.caption)
                Slider(value: Binding(get: { settings.trimDB }, set: { value in edit { $0.trimDB = value } }), in: -24...0, step: 0.5)
                Toggle("Reference bypass", isOn: Binding(get: { settings.referenceBypass }, set: { value in edit { $0.referenceBypass = value } }))
                    .toggleStyle(AeonToggleStyle())
                    .accessibilityIdentifier("aeon.correction.reference")
                Text("Reference bypass disables EQ, correction, ReplayGain, processing trim and protection. Your listening volume stays in control. Settings, the fixed DSP delay and native route conversion remain.").font(.caption).foregroundStyle(AeonOrbit.secondary)
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            }.padding(.top, 10)
        }.foregroundStyle(AeonOrbit.ink).tint(AeonOrbit.ink)
        .sheet(isPresented: $choosingProfile) {
            CorrectionCatalogPicker(saved: settings.profiles) { profile in
                pending = profile
                message = nil
                choosingProfile = false
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .json, .data]) { result in
            guard case .success(let url) = result else { return }
            let selectedKind = kind
            DispatchQueue.global(qos: .userInitiated).async {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 65536 else { throw DSPError.invalid("Profile exceeds 64 KiB.") }
                    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                    let data = try handle.read(upToCount: 65537) ?? Data()
                    let parsed = try CorrectionImport.parse(data, name: url.deletingPathExtension().lastPathComponent, kind: selectedKind)
                    DispatchQueue.main.async { pending = parsed; message = nil }
                } catch { DispatchQueue.main.async { message = error.localizedDescription } }
            }
        }
    }
    private func edit(_ change: (inout DSPSettings) -> Void) {
        var state = settings
        change(&state)
        guard state.profiles.count <= 32 else { message = "Up to 32 saved device profiles are supported."; return }
        playback.setDSP(state)
        message = nil
    }
    private func previewPreamp(_ profile: CorrectionProfile) -> Double {
        ParametricDSP.headroom(bands: profile.bands + (playback.snapshot?.eqEnabled == true ? playback.snapshot?.eqBands ?? [] : []), rate: rate, recommendedPreamp: profile.preampDB)
    }
}

private func correctionCredit(_ entry: BundledCorrection) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text("\(entry.creator) · \(entry.target)").font(.caption).bold()
        Text("Mode: \(entry.operatingMode). OPRA snapshot \(entry.snapshotDate), not the measurement date.").font(.caption)
        HStack {
            if let url = URL(string: entry.sourceURL) { Link("OPRA record", destination: url) }
            if let url = URL(string: entry.originalURL) { Link("Measurement", destination: url) }
        }.font(.caption)
        Text("Profile data: \(entry.license)").font(.caption)
    }
}

private struct CorrectionCatalogPicker: View {
    let saved: [CorrectionProfile]
    let select: (CorrectionProfile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        AeonSheet {
            VStack(alignment: .leading, spacing: AeonTheme.Space.medium) {
                HStack {
                    AeonDisplayText("Device profiles", size: 30, maximumLines: 2)
                    Spacer()
                    Button("DONE") { dismiss() }
                }
                TextField("Search exact model or saved room", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("aeon.correction.search")
                ScrollView {
                    VStack(alignment: .leading, spacing: AeonTheme.Space.large) {
                        Text("Choose the exact model and variant. These measurements are tonal starting points, not individual fit or hearing calibration. Previewing does not change playback.").font(.caption)
                        if case .failure(let error) = CorrectionCatalog.loaded { Text(error.localizedDescription).font(.caption) }
                        ForEach(CorrectionCatalog.profiles.filter { $0.matches(query) }) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Button { select(entry.profile) } label: {
                                    HStack {
                                        Text(entry.profile.name).font(.headline)
                                        Spacer()
                                        Text("PREVIEW").font(.caption)
                                    }.frame(minHeight: 44).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("aeon.correction.profile.\(entry.id)")
                                correctionCredit(entry)
                            }
                        }
                        let personal = saved.filter { profile in
                            !CorrectionCatalog.profiles.contains(where: { $0.id == profile.id }) &&
                            (query.isEmpty || profile.name.localizedCaseInsensitiveContains(query))
                        }
                        if !personal.isEmpty {
                            AeonLabel(text: "Saved imports and rooms")
                            ForEach(personal) { profile in
                                Button(profile.name) { select(profile) }.frame(minHeight: 44)
                            }
                        }
                        if let path = Bundle.main.path(forResource: "opra-logo", ofType: "png", inDirectory: "CorrectionCatalog"),
                           let logo = UIImage(contentsOfFile: path) {
                            Image(uiImage: logo).resizable().scaledToFit().frame(width: 140).accessibilityLabel("OPRA")
                        }
                        Text("OPRA is an open repository of product information, measurements and EQ presets. This offline subset preserves the published filters and preamps; Aeon converts their storage format.").font(.caption)
                        Link("OPRA project and creators", destination: URL(string: "https://github.com/opra-project/OPRA")!)
                        Link("Data license: Creative Commons BY-SA 4.0", destination: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!)
                        if let url = Bundle.main.url(forResource: "profiles", withExtension: "json", subdirectory: "CorrectionCatalog"),
                           let license = Bundle.main.url(forResource: "LICENSE", withExtension: "md", subdirectory: "CorrectionCatalog") {
                            ShareLink("Share catalogue data and license", items: [url, license])
                        }
                    }
                }
            }.padding(AeonTheme.Space.edge)
        }
        .foregroundStyle(AeonOrbit.ink).tint(AeonOrbit.ink)
        .presentationDetents([.large])
    }
}
