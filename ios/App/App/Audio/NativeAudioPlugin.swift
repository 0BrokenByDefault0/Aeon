import Capacitor
import Foundation

@objc(NativeAudioPlugin)
public final class NativeAudioPlugin: CAPPlugin, CAPBridgedPlugin, PlaybackCoordinatorDelegate {
    public let identifier = "NativeAudioPlugin"
    public let jsName = "NativeAudio"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "initialize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "load", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "toggle", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "seek", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "next", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "previous", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updateQueue", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setVolume", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setReplayGainMode", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setReplayGainPreamp", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setEQEnabled", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setEQBands", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getDiagnostics", returnType: CAPPluginReturnPromise)
    ]

    private var coordinator: PlaybackCoordinator?
    private var mediaStore: MediaStore?
    private var setupFailure: PlaybackFailure?

    public override func load() {
        super.load()
        guard coordinator == nil, setupFailure == nil else { return }
        do {
            let fileManager = FileManager.default
            let applicationSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let aeonRoot = applicationSupport.appendingPathComponent("Aeon", isDirectory: true)
            let mediaStore = try MediaStore(baseURL: applicationSupport, fileManager: fileManager)
            let graph = AudioEngineGraph()
            let scheduler = QueueScheduler(graph: graph, resolver: mediaStore)
            let stateStore = PlaybackStateStore(baseURL: aeonRoot, fileManager: fileManager)
            let diagnostics = DiagnosticsLog(
                url: aeonRoot.appendingPathComponent("diagnostics.jsonl", isDirectory: false),
                fileManager: fileManager
            )
            let coordinator = PlaybackCoordinator(
                scheduler: scheduler,
                graph: graph,
                mediaStore: mediaStore,
                stateStore: stateStore,
                diagnostics: diagnostics
            )
            coordinator.delegate = self
            self.mediaStore = mediaStore
            self.coordinator = coordinator
        } catch {
            setupFailure = PlaybackFailure(
                code: "engine_setup_failed",
                message: "Native audio could not be prepared",
                recoverable: false,
                trackID: nil
            )
        }
    }

    deinit {
        mediaStore?.releaseAll()
    }

    @objc func initialize(_ call: CAPPluginCall) {
        perform(call) { $0.initialize(completion: $1) }
    }

    @objc func load(_ call: CAPPluginCall) {
        guard let arguments: LoadArguments = decode(call) else { return }
        perform(call) {
            $0.load(
                trackID: arguments.trackID,
                mediaRef: arguments.mediaRef,
                queue: arguments.queue,
                index: arguments.index,
                completion: $1
            )
        }
    }

    @objc func play(_ call: CAPPluginCall) {
        perform(call) { $0.play(completion: $1) }
    }

    @objc func pause(_ call: CAPPluginCall) {
        perform(call) { $0.pause(completion: $1) }
    }

    @objc func toggle(_ call: CAPPluginCall) {
        perform(call) { $0.toggle(completion: $1) }
    }

    @objc func seek(_ call: CAPPluginCall) {
        guard let seconds = call.getDouble("seconds") else { rejectInvalid(call); return }
        perform(call) { $0.seek(seconds: seconds, completion: $1) }
    }

    @objc func next(_ call: CAPPluginCall) {
        perform(call) { $0.next(completion: $1) }
    }

    @objc func previous(_ call: CAPPluginCall) {
        perform(call) { $0.previous(completion: $1) }
    }

    @objc func setQueue(_ call: CAPPluginCall) {
        guard let arguments: QueueArguments = decode(call) else { return }
        perform(call) {
            $0.setQueue(
                items: arguments.items,
                index: arguments.index,
                revision: arguments.revision,
                completion: $1
            )
        }
    }

    @objc func updateQueue(_ call: CAPPluginCall) {
        guard let arguments: QueueArguments = decode(call) else { return }
        perform(call) {
            $0.updateQueue(
                items: arguments.items,
                index: arguments.index,
                revision: arguments.revision,
                completion: $1
            )
        }
    }

    @objc func setVolume(_ call: CAPPluginCall) {
        guard let value = call.getFloat("value") else { rejectInvalid(call); return }
        perform(call) { $0.setVolume(value, completion: $1) }
    }

    @objc func setReplayGainMode(_ call: CAPPluginCall) {
        guard let rawValue = call.getString("mode"), let mode = ReplayGainMode(rawValue: rawValue) else {
            rejectInvalid(call)
            return
        }
        perform(call) { $0.setReplayGainMode(mode, completion: $1) }
    }

    @objc func setReplayGainPreamp(_ call: CAPPluginCall) {
        guard let db = call.getDouble("db") else { rejectInvalid(call); return }
        perform(call) { $0.setReplayGainPreamp(db, completion: $1) }
    }

    @objc func setEQEnabled(_ call: CAPPluginCall) {
        guard let enabled = call.getBool("enabled") else { rejectInvalid(call); return }
        perform(call) { $0.setEQEnabled(enabled, completion: $1) }
    }

    @objc func setEQBands(_ call: CAPPluginCall) {
        guard let arguments: EQBandsArguments = decode(call) else { return }
        perform(call) { $0.setEQBands(arguments.bands, completion: $1) }
    }

    @objc func getState(_ call: CAPPluginCall) {
        guard let coordinator = readyCoordinator(for: call) else { return }
        coordinator.getState { [weak self] snapshot in
            self?.resolve(call, snapshot: snapshot)
        }
    }

    @objc func getDiagnostics(_ call: CAPPluginCall) {
        guard let coordinator = readyCoordinator(for: call) else { return }
        coordinator.getDiagnostics { entries in
            call.resolve(with: DiagnosticsResponse(entries: entries))
        }
    }

    func playbackCoordinator(
        _ coordinator: PlaybackCoordinator,
        didPublish snapshot: PlaybackSnapshot,
        events: [PlaybackCoordinatorEvent]
    ) {
        guard let data = try? Self.encoder().encodeJSObject(snapshot) else { return }
        for event in events {
            notifyListeners(event.rawValue, data: data)
        }
    }

    func playbackCoordinator(
        _ coordinator: PlaybackCoordinator,
        didFail failure: PlaybackFailure,
        version: UInt64
    ) {
        let data = failureData(failure, version: version)
        if Self.mediaFailureCodes.contains(failure.code) {
            notifyListeners("mediaUnavailable", data: data)
        }
        notifyListeners("playbackError", data: data)
    }

    private func perform(
        _ call: CAPPluginCall,
        command: (PlaybackCoordinator, @escaping PlaybackCommandCompletion) -> Void
    ) {
        guard let coordinator = readyCoordinator(for: call) else { return }
        command(coordinator) { [weak self] result in
            switch result {
            case .success(let snapshot):
                self?.resolve(call, snapshot: snapshot)
            case .failure(let failure):
                self?.reject(call, failure: failure)
            }
        }
    }

    private func readyCoordinator(for call: CAPPluginCall) -> PlaybackCoordinator? {
        if let coordinator { return coordinator }
        let failure = setupFailure ?? PlaybackFailure(
            code: "engine_unavailable",
            message: "Native audio is unavailable",
            recoverable: false,
            trackID: nil
        )
        reject(call, failure: failure)
        return nil
    }

    private func resolve(_ call: CAPPluginCall, snapshot: PlaybackSnapshot) {
        call.resolve(with: snapshot, encoder: Self.encoder())
    }

    private func reject(_ call: CAPPluginCall, failure: PlaybackFailure) {
        call.reject(
            failure.message,
            failure.code,
            failure,
            failureData(failure, version: nil)
        )
    }

    private func failureData(_ failure: PlaybackFailure, version: UInt64?) -> JSObject {
        var data: JSObject = [
            "code": failure.code,
            "message": failure.message,
            "recoverable": failure.recoverable
        ]
        if let trackID = failure.trackID { data["trackID"] = trackID }
        if let version { data["version"] = NSNumber(value: version) }
        return data
    }

    private func decode<T: Decodable>(_ call: CAPPluginCall) -> T? {
        do {
            return try call.decode(T.self)
        } catch {
            rejectInvalid(call)
            return nil
        }
    }

    private func rejectInvalid(_ call: CAPPluginCall) {
        call.reject("Invalid native audio arguments", "invalid_arguments")
    }

    private static func encoder() -> JSValueEncoder {
        JSValueEncoder(optionalEncodingStrategy: .explicitNulls, dateEncodingStrategy: .millisecondsSince1970)
    }

    private static let mediaFailureCodes: Set<String> = [
        "decoder_error",
        "format_unsupported",
        "media_missing",
        "media_open_failed",
        "media_permission",
        "migration_required"
    ]

    private struct LoadArguments: Decodable {
        let trackID: String
        let mediaRef: MediaReference
        let queue: [QueueItem]?
        let index: Int?
    }

    private struct QueueArguments: Decodable {
        let items: [QueueItem]
        let index: Int
        let revision: UInt64
    }

    private struct EQBandsArguments: Decodable {
        let bands: [EQBand]
    }

    private struct DiagnosticsResponse: Encodable {
        let entries: [DiagnosticEntry]
    }
}

@objc(AeonBridgeViewController)
final class AeonBridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        super.capacitorDidLoad()
        bridge?.registerPluginInstance(NativeAudioPlugin())
    }
}
