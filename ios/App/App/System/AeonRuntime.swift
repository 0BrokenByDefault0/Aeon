import Foundation

/// The one running container, for surfaces the SwiftUI tree does not own: App Intents,
/// CarPlay, Spotlight continuation and sheets presented far from the root.
@MainActor
enum AeonRuntime {
    static weak var container: AppContainer?

    /// Posted with an album ID as the object to open that record in the Library.
    static let showAlbumNotification = Notification.Name("app.aeon.show-album")

    static var services: AppServices? { container?.services }

    /// Services are built synchronously when the container starts, but an intent can
    /// arrive while a launch is still settling; wait briefly rather than failing at once.
    static func awaitServices(timeout: TimeInterval = 5) async -> AppServices? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let services, case .ready? = container?.launchState { return services }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return services
    }
}
