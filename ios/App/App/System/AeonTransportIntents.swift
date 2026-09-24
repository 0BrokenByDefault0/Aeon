import AppIntents
import Foundation

/// Transport intents shared by the app (Siri, Shortcuts, Action button) and the widget
/// extension (Control Center and Lock Screen controls). They conform to
/// `AudioPlaybackIntent`, so the system performs them in the app's process, where the
/// player lives; the extension compiles them only so its controls can name them.
enum AeonTransportCommand: String {
    case toggle, play, pause, next, previous
}

@MainActor
enum AeonTransport {
    static func perform(_ command: AeonTransportCommand) async throws {
        #if AEON_WIDGET_EXTENSION
        // Never reached: the system routes AudioPlaybackIntent to the app process.
        _ = command
        #else
        guard let playback = await AeonIntentSupport.readyPlayback() else {
            throw AeonIntentError.libraryUnavailable
        }
        switch command {
        case .toggle: playback.toggle()
        case .play: playback.play()
        case .pause: playback.pause()
        case .next: playback.next()
        case .previous: playback.previous()
        }
        #endif
    }
}

enum AeonIntentError: Error, CustomLocalizedStringResourceConvertible {
    case libraryUnavailable
    case nothingToPlay

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .libraryUnavailable: return "ISOLATION is still opening your library. Try again in a moment."
        case .nothingToPlay: return "There is nothing to play yet."
        }
    }
}

struct AeonPlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses the record in ISOLATION.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AeonTransport.perform(.toggle)
        return .result()
    }
}

struct AeonResumeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume Listening"
    static let description = IntentDescription("Continues the record that was last playing in ISOLATION.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AeonTransport.perform(.play)
        return .result()
    }
}

struct AeonPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause"
    static let description = IntentDescription("Pauses ISOLATION.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AeonTransport.perform(.pause)
        return .result()
    }
}

struct AeonNextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description = IntentDescription("Skips to the next track in the ISOLATION queue.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AeonTransport.perform(.next)
        return .result()
    }
}

struct AeonPreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let description = IntentDescription("Returns to the previous track in the ISOLATION queue.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await AeonTransport.perform(.previous)
        return .result()
    }
}
