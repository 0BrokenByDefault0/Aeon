import UIKit
import XCTest

final class AeonScreenMatrixTests: XCTestCase {
    func testAppearanceAccessibilityAndSystemThemeMatrixRemainNativeAndDark() {
        let cases: [(String, [String])] = [
            ("normal", []),
            ("ax5", ["-AeonAX5Testing"]),
            ("increase-contrast", ["-AeonIncreaseContrastTesting"]),
            ("reduce-transparency", ["-AeonReduceTransparencyTesting"]),
            ("reduce-motion", ["-AeonReduceMotionTesting"]),
            ("system-light", ["-AeonSystemLightTesting"]),
            ("system-dark", ["-AeonSystemDarkTesting"])
        ]

        for (name, arguments) in cases {
            let app = launch(["-AeonSkyFixture", "small"] + arguments)
            XCTAssertTrue(app.descendants(matching: .any)["aeon.root"].waitForExistence(timeout: 12), name)
            let device = deviceName(for: app)
            for (orientation, orientationName) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
                XCUIDevice.shared.orientation = orientation
                XCTAssertTrue(app.descendants(matching: .any)["aeon.root"].waitForExistence(timeout: 12), "\(name)-\(orientationName)")
                let frame = app.windows.firstMatch.frame
                XCTAssertEqual(frame.width > frame.height, orientation.isLandscape, "\(name)-\(orientationName)")
                XCTAssertLessThan(meanLuminance(app.screenshot().image), 0.35, "\(name)-\(orientationName)")
                capture(app, name: "matrix-\(device)-\(name)-\(orientationName)")
            }
            app.terminate()
        }
    }

    func testPortraitAndLandscapeStayReachableAtAX5() {
        let app = launch([
            "-AeonPlaybackFixture", "loaded",
            "-AeonAX5Testing"
        ])
        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 12))
        capture(app, name: "matrix-\(deviceName(for: app))-ax5-portrait")
        openNavigationIfNeeded(in: app)
        app.buttons["aeon.navigation.settings"].tap()
        let erase = app.buttons["aeon.settings.erase"]
        scroll(in: app, until: erase)
        XCTAssertTrue(erase.isHittable)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)["aeon.root"].waitForExistence(timeout: 5))
        openNavigationIfNeeded(in: app)
        let sky = app.buttons["aeon.navigation.sky"]
        XCTAssertTrue(sky.isHittable)
        sky.tap()
        openNavigationIfNeeded(in: app)
        app.buttons["aeon.navigation.settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.screen"].waitForExistence(timeout: 5))
        let window = app.windows.firstMatch.frame
        let settingsScroll = app.scrollViews.firstMatch
        if min(window.width, window.height) >= 700 {
            XCTAssertGreaterThanOrEqual(settingsScroll.frame.width, 500)
        } else {
            XCTAssertGreaterThan(settingsScroll.frame.width, window.width * 0.65)
        }
        XCTAssertLessThanOrEqual(settingsScroll.frame.maxX, window.maxX + 0.5)
        let storage = app.staticTexts["aeon.settings.storage-value"]
        scroll(in: app, until: storage)
        XCTAssertLessThanOrEqual(storage.frame.maxX, window.maxX + 0.5)
        XCTAssertGreaterThan(storage.frame.height, 40)
        scroll(in: app, until: erase)
        XCTAssertLessThanOrEqual(erase.frame.maxX, window.maxX + 0.5)
        assertVisibleTextFitsHorizontally(in: app, window: window)
        capture(app, name: "reachability-\(deviceName(for: app))-ax5-settings-landscape")

        if min(window.width, window.height) >= 700 {
            let sidebarEdge = app.buttons["aeon.navigation.sky"].frame.maxX
            XCTAssertGreaterThanOrEqual(
                app.descendants(matching: .any)["aeon.settings.screen"].frame.minX,
                sidebarEdge
            )

            app.buttons["aeon.navigation.library"].tap()
            let libraryCount = app.staticTexts["aeon.library.count"]
            XCTAssertTrue(libraryCount.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(libraryCount.frame.minX, sidebarEdge)
            capture(app, name: "reachability-ipad-ax5-library-landscape")

            app.buttons["aeon.navigation.playlists"].tap()
            let playlists = app.descendants(matching: .any)["aeon.playlists.screen"]
            XCTAssertTrue(playlists.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(playlists.frame.minX, sidebarEdge)
            capture(app, name: "reachability-ipad-ax5-playlists-landscape")

            app.buttons["aeon.player.open"].tap()
            let playerControl = app.buttons["aeon.player.primary-toggle"]
            XCTAssertTrue(playerControl.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(playerControl.frame.minX, sidebarEdge)
            capture(app, name: "reachability-ipad-ax5-player-landscape")
        }
    }

    func testCapturesSkyEmptyImportUnchartedConstellationAndPlanetStates() {
        var app = launch(["-AeonSkyFixture", "empty"])
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.empty"].waitForExistence(timeout: 12))
        capture(app, name: "screen-empty")
        XCTAssertTrue(app.buttons["aeon.library.import.files"].isHittable)
        XCTAssertTrue(app.buttons["aeon.library.import.folder"].isHittable)
        capture(app, name: "screen-import")

        app.terminate()
        app = launch(["-AeonSkyFixture", "uncharted"])
        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 12))
        capture(app, name: "screen-uncharted")

        app.terminate()
        app = launch(["-AeonSkyFixture", "small"])
        let canvas = app.images["aeon.sky.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 12))
        canvas.pinch(withScale: 2.2, velocity: 1.5)
        capture(app, name: "screen-constellation")

        app.terminate()
        app = launch(["-AeonSkyFixture", "planet-selected"])
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.planet-selection"].waitForExistence(timeout: 12))
        capture(app, name: "screen-planet-selected")
    }

    func testCapturesLibraryGridListAlbumEditorAndIPadSplitStates() {
        let app = launch(["-AeonLibraryFixture", "populated"])
        openNavigationIfNeeded(in: app)
        app.buttons["aeon.navigation.library"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.library.screen"].waitForExistence(timeout: 8))
        capture(app, name: "screen-library-grid")
        app.buttons["aeon.library.density.list"].tap()
        capture(app, name: "screen-library-list")

        let album = app.buttons["aeon.library.album.library-fixture-album-12"]
        scroll(in: app, until: album)
        album.tap()
        XCTAssertTrue(app.buttons["aeon.album.close"].waitForExistence(timeout: 6))
        capture(app, name: "screen-album-detail")
        if app.windows.firstMatch.frame.width >= 700 {
            XCTAssertTrue(app.images["aeon.sky.canvas"].exists)
            capture(app, name: "screen-ipad-split")
        }
        app.buttons["aeon.album.edit"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.album.editor"].waitForExistence(timeout: 5))
        capture(app, name: "screen-album-editor")
    }

    func testCapturesPlaybackPausedPlayingErrorQueueAndPlaylistSettingsStates() {
        var app = launch(["-AeonPlaybackFixture", "loaded"])
        XCTAssertTrue(app.buttons["aeon.player.open"].waitForExistence(timeout: 12))
        app.buttons["aeon.player.open"].tap()
        XCTAssertTrue(app.buttons["aeon.player.primary-toggle"].waitForExistence(timeout: 5))
        capture(app, name: "screen-player-paused")
        app.buttons["aeon.player.primary-toggle"].tap()
        XCTAssertTrue(app.staticTexts["PLAYING"].waitForExistence(timeout: 5))
        capture(app, name: "screen-player-playing")
        app.buttons["aeon.player.queue.open"].tap()
        let first = app.images["aeon.player.queue.drag.playback-fixture-track-2"]
        let second = app.images["aeon.player.queue.drag.playback-fixture-track-3"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.press(forDuration: 0.6, thenDragTo: second)
        capture(app, name: "screen-queue-drag")

        app.terminate()
        app = launch(["-AeonPlaybackFixture", "error"])
        XCTAssertTrue(app.buttons["aeon.player.open"].waitForExistence(timeout: 12))
        app.buttons["aeon.player.open"].tap()
        XCTAssertTrue(app.buttons["aeon.player.failure"].waitForExistence(timeout: 5))
        capture(app, name: "screen-player-error")

        app.terminate()
        app = launch(["-AeonSkyFixture", "empty"])
        openNavigationIfNeeded(in: app)
        app.buttons["aeon.navigation.playlists"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.playlists.screen"].waitForExistence(timeout: 8))
        capture(app, name: "screen-playlists-empty")
        let name = app.textFields["aeon.playlists.name"]
        name.tap()
        name.typeText("Screen Matrix Route\n")
        let route = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Screen Matrix Route")).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 5))
        route.tap()
        XCTAssertTrue(app.staticTexts["Empty route."].waitForExistence(timeout: 5))
        capture(app, name: "screen-playlist-detail")
        app.buttons["aeon.playlists.detail.close"].tap()
        openNavigationIfNeeded(in: app)
        app.buttons["aeon.navigation.settings"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.settings.screen"].waitForExistence(timeout: 5))
        capture(app, name: "screen-settings")
    }

    private func deviceName(for app: XCUIApplication) -> String {
        let frame = app.windows.firstMatch.frame
        return min(frame.width, frame.height) >= 700 ? "ipad" : "iphone"
    }

    private func launch(_ arguments: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += arguments
        app.launch()
        return app
    }

    private func openNavigationIfNeeded(in app: XCUIApplication) {
        if app.buttons["aeon.navigation.sky"].waitForExistence(timeout: 2) { return }
        let menu = app.buttons["aeon.navigation.menu"]
        if menu.waitForExistence(timeout: 10), menu.label == "Open navigation" { menu.tap() }
        XCTAssertTrue(app.buttons["aeon.navigation.sky"].waitForExistence(timeout: 4))
    }

    private func scroll(in app: XCUIApplication, until element: XCUIElement) {
        let window = app.windows.firstMatch.frame
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<30 where !element.exists || !element.isHittable {
            if min(window.width, window.height) >= 700, scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.isHittable)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        XCTAssertEqual(app.webViews.count, 0, "\(name) must remain a native SwiftUI surface")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertVisibleTextFitsHorizontally(in app: XCUIApplication, window: CGRect) {
        for index in 0..<app.staticTexts.count {
            let element = app.staticTexts.element(boundBy: index)
            let frame = element.frame
            guard frame.intersects(window) else { continue }
            XCTAssertGreaterThanOrEqual(frame.minX, window.minX - 0.5, element.label)
            XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 0.5, element.label)
        }
    }

    private func meanLuminance(_ image: UIImage) -> CGFloat {
        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let cgImage = image.cgImage,
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return 1 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let total = stride(from: 0, to: pixels.count, by: 4).reduce(CGFloat.zero) { value, offset in
            let red = CGFloat(pixels[offset]) / 255
            let green = CGFloat(pixels[offset + 1]) / 255
            let blue = CGFloat(pixels[offset + 2]) / 255
            return value + 0.2126 * red + 0.7152 * green + 0.0722 * blue
        }
        return total / CGFloat(width * height)
    }
}
