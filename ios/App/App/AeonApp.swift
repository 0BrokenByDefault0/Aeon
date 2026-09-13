import SwiftUI

@main
struct AeonApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _container = StateObject(wrappedValue: AppContainer.production())
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
