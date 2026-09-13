import SwiftUI

@main
struct AeonApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var container: AppContainer

    init() {
        _container = StateObject(wrappedValue: AppContainer.production())
    }

    var body: some Scene {
        WindowGroup {
            AeonRootView(container: container)
        }
    }
}
