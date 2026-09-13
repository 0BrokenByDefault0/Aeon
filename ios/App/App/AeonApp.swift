import SwiftUI

@main
struct AeonApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let deterministicSky = arguments.contains("-AeonSkyFixture")
        _container = StateObject(wrappedValue: deterministicSky ? AppContainer.inMemory() : AppContainer.production())
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
