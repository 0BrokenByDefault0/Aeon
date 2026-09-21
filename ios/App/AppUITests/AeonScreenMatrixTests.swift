import UIKit
import XCTest

final class AeonScreenMatrixTests: XCTestCase {
    func testDefinitiveSemanticReviewCaptures() {
        var collectionCorePixels = 0
        let fixtures = [
            ("empty", 0, 0, 0), ("one", 1, 0, 0), ("one-focused", 1, 0, 0),
            ("three", 3, 1, 0), ("artist-focused", 3, 1, 0),
            ("fourteen", 14, 5, 0), ("fifteen", 15, 5, 1),
            ("thirty-three", 33, 11, 2), ("planet-selected", 33, 11, 2)
        ]
        for (name, albums, artists, planets) in fixtures {
            let app = launch(["-AeonSkyFixture", name, "-AeonAccessibilityTesting"])
            let canvas = app.images["aeon.sky.canvas"]
            XCTAssertTrue(canvas.waitForExistence(timeout: 12))
            XCTAssertEqual(canvas.value as? String, "\(albums) albums, \(artists) artist constellations, \(planets) worlds")
            if name == "one-focused" {
                let readout = app.descendants(matching: .any)["aeon.sky.star-selection"]
                XCTAssertTrue(readout.exists)
                XCTAssertTrue(readout.label.contains("Channel Orange"))
            }
            if name == "one" || name == "one-focused" {
                let star = app.buttons["aeon.sky.accessibility.star.fixture-album-0"]
                XCTAssertTrue(star.exists)
                let anchor = CGPoint(x: star.frame.midX - canvas.frame.minX,
                                     y: star.frame.midY - canvas.frame.minY)
                let corePixels = luminousCorePixels(in: canvas.screenshot().image, at: anchor)
                if name == "one" {
                    collectionCorePixels = corePixels
                    XCTAssertGreaterThan(corePixels, 0, "The collection star must be visibly represented")
                } else {
                    XCTAssertGreaterThan(corePixels, max(20, collectionCorePixels * 3),
                                         "Focus must enlarge the rendered star, not merely change camera state")
                }
            }
            if name == "artist-focused" {
                // Visual text is excluded from VoiceOver to avoid duplicating the
                // semantic spatial elements. Assert those, then inspect native pixels.
                for (index, title) in ["Channel Orange", "Blonde", "Endless"].enumerated() {
                    let star = app.buttons["aeon.sky.accessibility.star.fixture-album-\(index)"]
                    XCTAssertTrue(star.exists)
                    XCTAssertTrue(star.label.contains(title), title)
                }
            }
            capture(app, name: "definitive-\(name)")
            app.terminate()
        }
        var app = launch(["-AeonLibraryFixture", "populated"])
        app.buttons["aeon.navigation.library"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.library.screen"].waitForExistence(timeout: 8))
        capture(app, name: "definitive-library")
        app.terminate()
        app = launch(["-AeonPlaybackFixture", "loaded"])
        XCTAssertTrue(app.buttons["aeon.player.open"].waitForExistence(timeout: 12))
        app.buttons["aeon.player.open"].tap()
        XCTAssertTrue(app.buttons["aeon.player.primary-toggle"].waitForExistence(timeout: 5))
        capture(app, name: "definitive-now-playing")
        app.buttons["aeon.player.eq.open"].tap()
        let frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        for frequency in frequencies {
            let band = app.descendants(matching: .any)["aeon.player.eq.band.\(frequency)"]
            XCTAssertTrue(band.waitForExistence(timeout: 4))
            XCTAssertTrue(band.isHittable)
        }
        capture(app, name: "definitive-eq-ten-bands")
        let firstBand = app.descendants(matching: .any)["aeon.player.eq.band.31"]
        let before = firstBand.value as? String
        firstBand.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: firstBand.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        XCTAssertNotEqual(firstBand.value as? String, before)
        app.buttons["aeon.player.eq.preset.flat"].tap()
        for frequency in frequencies {
            XCTAssertEqual(app.descendants(matching: .any)["aeon.player.eq.band.\(frequency)"].value as? String, "0 decibels")
        }
        app.buttons["aeon.player.close"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["aeon.player.close"])], timeout: 5), .completed)
        app.buttons["aeon.player.open"].tap()
        XCTAssertTrue(app.buttons["aeon.player.primary-toggle"].waitForExistence(timeout: 5))
        let queue = app.buttons["aeon.player.queue.open"]
        scroll(in: app, until: queue)
        queue.tap()
        let menu = app.buttons["aeon.track.actions.playback-fixture-track-2"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        for title in ["PLAY NEXT", "ADD TO QUEUE", "ADD TO PLAYLIST", "SHOW ALBUM", "TRACK INFO", "REMOVE FROM QUEUE"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 3), title)
        }
        capture(app, name: "definitive-track-actions")
        app.buttons["ADD TO PLAYLIST"].tap()
        let playlistName = app.textFields["Playlist name"]
        XCTAssertTrue(playlistName.waitForExistence(timeout: 5))
        playlistName.tap(); playlistName.typeText("Context Route")
        app.buttons["CREATE AND ADD"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        app.buttons["SHOW ALBUM"].tap()
        XCTAssertTrue(app.buttons["aeon.album.close"].waitForExistence(timeout: 5))
    }

    func testCorrectiveDeviceReviewCaptures() {
        for fixture in ["populated", "thirty-three", "planet-medium", "planet-selected", "one-focused", "artist-focused"] {
            let app = launch(["-AeonSkyFixture", fixture])
            XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 12))
            let overview = app.buttons["aeon.sky.galaxy"]
            // Some simulator runtimes omit the system status bar from the app AX tree.
            let statusBar = app.statusBars.firstMatch
            let statusBottom = statusBar.exists ? statusBar.frame.maxY : app.windows.firstMatch.frame.minY + 20
            XCTAssertGreaterThanOrEqual(overview.frame.minY, statusBottom,
                                       "Sky utilities must clear the status bar")
            capture(app, name: "corrective-sky-\(fixture)")
            app.terminate()
        }
        let app = launch(["-AeonPlaybackFixture", "loaded"])
        XCTAssertTrue(app.buttons["aeon.player.open"].waitForExistence(timeout: 12))
        app.buttons["aeon.player.open"].tap()
        let repeatControl = app.buttons["aeon.player.repeat"]
        scroll(in: app, until: repeatControl)
        for mode in ["Off", "All", "One"] {
            XCTAssertEqual(repeatControl.value as? String, mode)
            capture(app, name: "corrective-repeat-\(mode.lowercased())")
            repeatControl.tap()
        }
        XCTAssertEqual(repeatControl.value as? String, "Off")
        app.buttons["aeon.player.queue.open"].tap()
        let first = app.images["aeon.player.queue.drag.playback-fixture-track-2"]
        let last = app.images["aeon.player.queue.drag.playback-fixture-track-3"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(first.frame.maxX, app.windows.firstMatch.frame.maxX - 8,
                                 "The entire queue drag target must fit inside the sheet")
        capture(app, name: "corrective-up-next-before")
        last.press(forDuration: 0.5, thenDragTo: first)
        XCTAssertLessThan(last.frame.midY, first.frame.midY, "The drop must commit the previewed order")
        capture(app, name: "corrective-up-next-reordered")
        XCTAssertFalse(app.staticTexts["Upcoming queue reordered."].exists)
        app.buttons["aeon.player.queue.close"].tap()
        app.buttons["aeon.player.queue.open"].tap()
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertLessThan(last.frame.midY, first.frame.midY, "Reopening must use the committed queue order")
        let secondPosition = app.staticTexts["aeon.player.queue.position.2"]
        XCTAssertEqual(secondPosition.frame.midY, last.frame.midY, accuracy: 1,
                       "Queue ordinals and Move Up/Down actions must follow the reordered rows")
        app.buttons["aeon.player.queue.close"].tap()
        let output = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Clay's AirPods Pro #2")).firstMatch
        scroll(in: app, until: output)
        XCTAssertTrue(output.isHittable)
        capture(app, name: "corrective-long-output-route")
        app.buttons["aeon.player.close"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["aeon.player.close"])], timeout: 5), .completed)
        app.buttons["aeon.player.open"].tap()
        let artwork = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Artwork for The Silver Chamber")).firstMatch
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        XCTAssertTrue(artwork.isHittable, "Reopening the player starts at its artwork")
        capture(app, name: "corrective-player-reopened")
    }

    func testCompactAlbumDetailCaptures() {
        var ordinaryTitleHeight: CGFloat = 0
        for (fixture, options, name) in [
            ("populated", [String](), "ordinary"),
            ("long-title", [String](), "long-title"),
            ("long-title", ["-AeonLargeTextTesting"], "long-title-large-text"),
            ("long-title", ["-AeonAX5Testing"], "long-title-accessibility")
        ] {
            let app = launch(["-AeonLibraryFixture", fixture] + options)
            app.buttons["aeon.navigation.library"].tap()
            let album = app.buttons["aeon.library.album.library-fixture-album-12"]
            scroll(in: app, until: album); album.tap()
            XCTAssertTrue(app.buttons["aeon.album.close"].waitForExistence(timeout: 5))
            capture(app, name: "corrective-album-\(name)")
            let title = app.staticTexts["aeon.album.title"]
            if name == "long-title" { ordinaryTitleHeight = title.frame.height }
            if name == "long-title-accessibility" {
                XCTAssertGreaterThan(title.frame.height, ordinaryTitleHeight * 1.2,
                                     "The accessibility fixture must actually scale the album title")
            }
            XCTAssertFalse(app.buttons["aeon.album.edit"].exists, "Edit belongs in overflow")
            let play = app.buttons["aeon.album.play"]
            if options.isEmpty { XCTAssertTrue(play.isHittable) }
            else { scroll(in: app, until: play); XCTAssertTrue(play.isHittable) }
            XCTAssertTrue(app.buttons["aeon.album.find-in-sky"].exists)
            app.terminate()
        }
    }

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
        let importMusic = app.buttons["aeon.library.import"]
        XCTAssertTrue(importMusic.isHittable)
        importMusic.tap()
        XCTAssertTrue(app.descendants(matching: .any)["aeon.import.sheet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["aeon.library.import.files"].isHittable)
        XCTAssertTrue(app.buttons["aeon.library.import.adopt"].isHittable)
        capture(app, name: "screen-import")

        app.terminate()
        app = launch(["-AeonSkyFixture", "uncharted"])
        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 12))
        capture(app, name: "screen-uncharted")

        app.terminate()
        app = launch(["-AeonSkyFixture", "small"])
        let canvas = app.images["aeon.sky.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 12))
        capture(app, name: "screen-small-collection-planets")
        canvas.pinch(withScale: 2.2, velocity: 1.5)
        capture(app, name: "screen-album-near")

        app.terminate()
        app = launch(["-AeonSkyFixture", "populated"])
        XCTAssertTrue(app.images["aeon.sky.canvas"].waitForExistence(timeout: 12))
        capture(app, name: "screen-populated-collection")

        app.terminate()
        app = launch(["-AeonSkyFixture", "album-selected"])
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.star-selection"].waitForExistence(timeout: 12))
        capture(app, name: "screen-album-focus")

        app.terminate()
        app = launch(["-AeonSkyFixture", "planet-selected"])
        XCTAssertTrue(app.descendants(matching: .any)["aeon.sky.planet-selection"].waitForExistence(timeout: 12))
        capture(app, name: "screen-planet-focus")
        let collection = app.buttons["aeon.sky.planet.galaxy"]
        XCTAssertTrue(collection.isHittable)
        collection.tap()
        Thread.sleep(forTimeInterval: 1)
        capture(app, name: "screen-return-to-collection")
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
        app.buttons["aeon.album.actions"].tap()
        XCTAssertTrue(app.buttons["aeon.album.edit"].waitForExistence(timeout: 3))
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
        let create = app.buttons["aeon.playlists.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let name = app.textFields["aeon.playlists.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
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

    private func luminousCorePixels(in image: UIImage, at anchor: CGPoint) -> Int {
        guard let source = image.cgImage else { return 0 }
        let size = 64
        let scale = CGFloat(source.width) / image.size.width
        let crop = CGRect(x: (anchor.x - 32) * scale,
                          y: (anchor.y - 32) * scale,
                          width: 64 * scale, height: 64 * scale)
        guard let core = source.cropping(to: crop) else { return 0 }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(core, in: CGRect(x: 0, y: 0, width: size, height: size))
        var litPixels = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            if red + green + blue > 300 { litPixels += 1 }
        }
        return litPixels
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

    private func scroll(
        in app: XCUIApplication,
        until element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch.frame
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<30 where !element.exists || !element.isHittable {
            if scrollView.exists {
                scrollView.swipeUp()
            } else {
                app.swipeUp()
            }
        }
        if !element.isHittable {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "unreachable-\(element.identifier)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail(
                """
                \(element.identifier) never became hittable.
                exists=\(element.exists) frame=\(element.exists ? "\(element.frame)" : "n/a")
                window=\(window) scrollView=\(scrollView.exists ? "\(scrollView.frame)" : "absent")
                """,
                file: file,
                line: line
            )
        }
    }

    private func capture(_ app: XCUIApplication, name: String) {
        XCTAssertEqual(app.webViews.count, 0, "\(name) must remain a native SwiftUI surface")
        var navigationButtons: [XCUIElement] = []
        if name.hasPrefix("definitive-") || name.hasPrefix("corrective-sky-") {
            if app.images["aeon.sky.canvas"].exists && !app.buttons["aeon.player.close"].exists {
                for destination in ["sky", "library", "playlists", "settings"] {
                    let button = app.buttons["aeon.navigation.\(destination)"]
                    XCTAssertTrue(button.waitForExistence(timeout: 5))
                    XCTAssertTrue(button.isHittable, "Sky navigation must remain available: \(destination)")
                    navigationButtons.append(button)
                }
            }
        }
        // App-scoped portrait capture resolves the app's composited layers. Full-screen
        // capture avoids the simulator's rotated app-frame cropping in landscape.
        let frame = app.windows.firstMatch.frame
        let screenshot = frame.width > frame.height ? XCUIScreen.main.screenshot() : app.screenshot()
        let renderedImage = screenshot.image
        for button in navigationButtons {
            let anchor = CGPoint(x: button.frame.midX - frame.minX, y: button.frame.midY - frame.minY)
            XCTAssertGreaterThan(luminousCorePixels(in: renderedImage, at: anchor), 8,
                                 "The captured dock must render \(button.identifier), not just expose a hit target")
        }
        guard let png = renderedImage.pngData() else {
            XCTFail("Native capture could not be encoded: \(name)")
            return
        }
        // Attach the exact pixels inspected above, without a second deferred screen snapshot.
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
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
