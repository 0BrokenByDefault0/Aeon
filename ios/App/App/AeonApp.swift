import SwiftUI

@main
struct AeonApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var container: AppContainer
    @Environment(\.scenePhase) private var scenePhase
    private let testArguments: [String]

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        testArguments = arguments
        let deterministicFixture = arguments.contains("-AeonSkyFixture")
            || arguments.contains("-AeonLibraryFixture")
            || arguments.contains("-AeonPlaybackFixture")
        _container = StateObject(wrappedValue: deterministicFixture ? AppContainer.inMemory() : AppContainer.production())
    }

    var body: some Scene {
        WindowGroup {
            AeonRootView(container: container)
                .modifier(AeonTestEnvironment(arguments: testArguments))
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { container.applicationDidEnterForeground() }
            else if phase == .background { container.applicationDidEnterBackground() }
        }
    }
}

private struct AeonTestEnvironment: ViewModifier {
    let arguments: [String]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .environment(
                \.dynamicTypeSize,
                arguments.contains("-AeonAX5Testing") ? .accessibility5 : (arguments.contains("-AeonLargeTextTesting") ? .xxxLarge : dynamicTypeSize)
            )
            .environment(
                \.colorScheme,
                arguments.contains("-AeonSystemLightTesting")
                    ? .light
                    : arguments.contains("-AeonSystemDarkTesting") ? .dark : colorScheme
            )
    }
}

enum AeonTestOverrides {
    private static let arguments = ProcessInfo.processInfo.arguments

    static let staticSky = arguments.contains("-AeonSkyFixture")
        || arguments.contains("-AeonLibraryFixture")
        || arguments.contains("-AeonPlaybackFixture")
    static let accessibilityText = arguments.contains("-AeonAX5Testing")
    static let increasedContrast = arguments.contains("-AeonIncreaseContrastTesting")
    static let reduceTransparency = arguments.contains("-AeonReduceTransparencyTesting")
    static let reduceMotion = arguments.contains("-AeonReduceMotionTesting")
}
