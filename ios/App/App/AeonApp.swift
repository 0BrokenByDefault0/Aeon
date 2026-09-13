import SwiftUI

@main
struct AeonApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let deterministicFixture = arguments.contains("-AeonSkyFixture") || arguments.contains("-AeonLibraryFixture")
        _container = StateObject(wrappedValue: deterministicFixture ? AppContainer.inMemory() : AppContainer.production())
    }

    var body: some Scene {
        WindowGroup {
            AeonRootView(container: container)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { container.applicationDidEnterForeground() }
        }
    }
}
