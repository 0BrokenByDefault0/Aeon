import AVFoundation
import Foundation

enum RouteLossAction: Equatable {
    case none
    case pauseAndRebuild
}

enum AudioSessionEvent: Equatable {
    case interruptionBegan
    case interruptionEnded(systemAllowsResume: Bool)
    case routeChanged(old: RouteDescriptor?, new: RouteDescriptor?, action: RouteLossAction)
    case mediaServicesLost
    case mediaServicesReset
    case secondaryAudioSilenced(Bool)
}

func routeLossAction(
    old: RouteDescriptor?,
    new: RouteDescriptor?,
    reason: AVAudioSession.RouteChangeReason
) -> RouteLossAction {
    guard reason == .oldDeviceUnavailable,
          let old,
          [.wired, .usb, .bluetooth].contains(old.kind),
          old.kind != new?.kind else { return .none }
    return .pauseAndRebuild
}

func interruptionShouldResume(systemAllowsResume: Bool, userIntent: PlaybackIntent) -> Bool {
    systemAllowsResume && userIntent == .playing
}

protocol AudioSessionActivating: AnyObject {
    func activate() throws
}

final class AudioSessionController: AudioSessionActivating {
    var onEvent: ((AudioSessionEvent) -> Void)?

    private let session: AVAudioSession
    private let center: NotificationCenter
    private let eventQueue: DispatchQueue
    private var observers: [NSObjectProtocol] = []

    init(
        session: AVAudioSession = .sharedInstance(),
        center: NotificationCenter = .default,
        eventQueue: DispatchQueue = DispatchQueue(label: "app.aeon.audio-session.events", qos: .userInitiated)
    ) {
        self.session = session
        self.center = center
        self.eventQueue = eventQueue
        observeNotifications()
    }

    func activate() throws {
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }

    /// Ask the hardware to run at the source's own rate.
    ///
    /// Without this iOS parks the session at 48 kHz and resamples the 44.1 kHz content
    /// that most collections are made of. `setPreferredSampleRate` is a hint the system
    /// may decline — on many Bluetooth routes it will — so this is best effort and never
    /// fails a load.
    ///
    /// Only call this while nothing is rendering. Changing the rate under a running
    /// engine forces a reconfiguration this app does not yet observe, so the caller is
    /// responsible for the "engine is idle" precondition.
    func preferSampleRate(_ rate: Double) {
        guard rate.isFinite, rate >= 8_000, rate <= 192_000 else { return }
        guard abs(session.sampleRate - rate) > 1 else { return }
        try? session.setPreferredSampleRate(rate)
    }

    var currentSampleRate: Double { session.sampleRate }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func outputRoute() -> RouteDescriptor? {
        Self.routeDescriptor(session.currentRoute.outputs.first, session: session)
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }

    private func observeNotifications() {
        observe(AVAudioSession.interruptionNotification) { [weak self] notification in
            guard let self,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                emit(.interruptionBegan)
            } else {
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                emit(.interruptionEnded(systemAllowsResume: AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)))
            }
        }
        observe(AVAudioSession.routeChangeNotification) { [weak self] notification in
            guard let self else { return }
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            let oldRoute = (notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
                .outputs.first.flatMap { Self.routeDescriptor($0, session: self.session) }
            let newRoute = outputRoute()
            emit(.routeChanged(
                old: oldRoute,
                new: newRoute,
                action: routeLossAction(old: oldRoute, new: newRoute, reason: reason)
            ))
        }
        observe(AVAudioSession.mediaServicesWereLostNotification) { [weak self] _ in self?.emit(.mediaServicesLost) }
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in self?.emit(.mediaServicesReset) }
        observe(AVAudioSession.silenceSecondaryAudioHintNotification) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt ?? 0
            self?.emit(.secondaryAudioSilenced(AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw) == .begin))
        }
    }

    private func observe(_ name: Notification.Name, handler: @escaping (Notification) -> Void) {
        observers.append(center.addObserver(forName: name, object: session, queue: nil, using: handler))
    }

    private func emit(_ event: AudioSessionEvent) {
        eventQueue.async { [weak self] in self?.onEvent?(event) }
    }

    private static func routeDescriptor(
        _ output: AVAudioSessionPortDescription?,
        session: AVAudioSession
    ) -> RouteDescriptor? {
        guard let output else { return nil }
        let channels = output.channels?.count
        return RouteDescriptor(
            kind: routeKind(output.portType),
            name: output.portName,
            sampleRate: session.sampleRate > 0 ? session.sampleRate : nil,
            channelCount: channels == 0 ? nil : channels
        )
    }

    private static func routeKind(_ portType: AVAudioSession.Port) -> AudioRouteKind {
        switch portType {
        case .builtInSpeaker, .builtInReceiver: return .speaker
        case .headphones, .headsetMic, .lineOut: return .wired
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return .bluetooth
        case .airPlay: return .airPlay
        case .usbAudio: return .usb
        default: return .unknown
        }
    }
}
