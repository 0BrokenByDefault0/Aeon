import XCTest
import WebKit
@testable import App

final class LegacyDataAccessTests: XCTestCase {
    func testMigrationControllerLoadsOnlyTheMigrationPage() {
        let controller = LegacyMigrationViewController()
        XCTAssertEqual(controller.instanceDescriptor().appStartPath, "legacy-migration.html")
    }

    @MainActor
    @available(iOS 15.0, *)
    func testMigrationControllerReadsTheExistingCapacitorOrigin() async throws {
        #if targetEnvironment(simulator)
        let seedController = AeonBridgeViewController()
        let seedWindow = UIWindow(frame: UIScreen.main.bounds)
        seedWindow.rootViewController = seedController
        seedWindow.isHidden = false
        seedController.loadViewIfNeeded()
        guard let seedWebView = seedController.webView else { return XCTFail("Seed web view missing") }
        try await waitForJavaScript("typeof dbClearAll === 'function' && db !== null", in: seedWebView)
        _ = try await callAsync("""
            await dbClearAll();
            await dbPut('albums',{id:'upgrade-album',title:'Upgrade',artist:'Aeon',art:new Blob(['cover'],{type:'image/jpeg'})});
            await dbPut('tracks',{id:'upgrade-blob',albumId:'upgrade-album',idx:1,title:'Embedded',artist:'Aeon',blob:new File(['signal'],'01 Embedded.flac',{type:'audio/flac'})});
            await dbPut('tracks',{id:'upgrade-path-1',albumId:'upgrade-album',idx:2,title:'Signal',artist:'Aeon',path:'Music/Aeon/Upgrade/02 Signal.m4a',bytes:42});
            await dbPut('tracks',{id:'upgrade-path-2',albumId:'upgrade-album',idx:3,title:'Return',artist:'Aeon',path:'Music/Aeon/Upgrade/03 Return.m4a',bytes:84});
            await dbPut('playlists',{id:'upgrade-playlist',name:'Route',items:[{albumId:'upgrade-album',trackId:'upgrade-path-1'}]});
            await dbPut('kv',{k:'skySeed',v:17});
            window.__aeonMigrationTestDB = db;
            db = null;
            return true;
            """, in: seedWebView)

        let probe = LegacyMigrationInventoryProbe()
        let completion = expectation(description: "Capacitor inventory read")
        var result: Result<LegacyMigrationInventorySnapshot, LegacyMigrationFailure>?
        probe.onCompletion = {
            result = $0
            completion.fulfill()
        }
        let migrationController = LegacyMigrationViewController(inventoryProbe: probe)
        let migrationWindow = UIWindow(frame: UIScreen.main.bounds)
        migrationWindow.rootViewController = migrationController
        migrationWindow.isHidden = false
        migrationController.loadViewIfNeeded()

        await fulfillment(of: [completion], timeout: 10)
        guard case .success(let snapshot) = result else {
            return XCTFail("Migration page did not read the seeded catalogue")
        }
        XCTAssertEqual(snapshot.ids[.albums], ["upgrade-album"])
        XCTAssertEqual(snapshot.ids[.tracks], ["upgrade-blob", "upgrade-path-1", "upgrade-path-2"])
        XCTAssertEqual(snapshot.ids[.playlists], ["upgrade-playlist"])
        let keyValueIDs = Set(snapshot.ids[.kv] ?? [])
        XCTAssertTrue(keyValueIDs.contains("skySeed"))
        // The legacy app writes its own key/value entries while it boots — settings on
        // every save, trackOrderFix as a one-time marker — so the seeded skySeed is not
        // the only key present. What matters is that nothing outside the legacy app's
        // own vocabulary appears in the snapshot.
        let legacyOwnedKeys: Set<String> = [
            "log", "skySeed", "settings", "seq", "lastPlayed", "plays", "trackOrderFix"
        ]
        XCTAssertTrue(keyValueIDs.isSubset(of: legacyOwnedKeys), "Unexpected keys: \(keyValueIDs)")
        XCTAssertEqual(snapshot.blobs.map(\.ownerID), ["upgrade-album", "upgrade-blob"])

        _ = try await callAsync("db = window.__aeonMigrationTestDB; await dbClearAll(); db = null; return true;", in: seedWebView)
        migrationWindow.isHidden = true
        seedWindow.isHidden = true
        #else
        throw XCTSkip("The automated upgrade probe uses an isolated simulator container")
        #endif
    }

    func testProbeAcceptsCompleteReadOnlyInventory() throws {
        let probe = LegacyMigrationInventoryProbe()
        let completed = expectation(description: "inventory completed")
        var result: Result<LegacyMigrationInventorySnapshot, LegacyMigrationFailure>?
        probe.onCompletion = {
            result = $0
            completed.fulfill()
        }

        try probe.receive(inventory: inventory(albums: 2, tracks: 2, playlists: 1, kv: 2))
        try probe.receive(page: page(
            .albums,
            ids: ["album-1", "album-2"],
            blobs: [blob(ownerID: "album-1", kind: .artwork)]
        ))
        try probe.receive(page: page(
            .tracks,
            ids: ["track-1", "track-2"],
            blobs: [blob(ownerID: "track-2", kind: .audio, fileName: "02 Song.flac")]
        ))
        try probe.receive(page: page(.playlists, ids: ["playlist-1"]))
        try probe.receive(page: page(.kv, ids: ["settings", "skySeed"]))
        try probe.finishInventory()

        wait(for: [completed], timeout: 1)
        guard case .success(let snapshot) = result else {
            return XCTFail("Expected a successful inventory")
        }
        XCTAssertEqual(snapshot.inventory.databaseName, "isolation-db")
        XCTAssertEqual(snapshot.ids[.albums], ["album-1", "album-2"])
        XCTAssertEqual(snapshot.ids[.tracks], ["track-1", "track-2"])
        XCTAssertEqual(snapshot.ids[.playlists], ["playlist-1"])
        XCTAssertEqual(snapshot.ids[.kv], ["settings", "skySeed"])
        XCTAssertEqual(snapshot.blobs.map(\.ownerID), ["album-1", "track-2"])
    }

    func testProbeRejectsMissingOrUnexpectedStores() {
        let probe = LegacyMigrationInventoryProbe()
        XCTAssertThrowsError(try probe.receive(inventory: LegacyMigrationInventory(
            databaseName: "isolation-db",
            schemaVersion: 1,
            counts: ["albums": 0, "tracks": 0, "playlists": 0]
        ))) { XCTAssertEqual($0 as? LegacyMigrationValidationError, .invalidCounts) }

        XCTAssertThrowsError(try LegacyMigrationInventoryProbe().receive(inventory: LegacyMigrationInventory(
            databaseName: "isolation-db",
            schemaVersion: 1,
            counts: ["albums": 0, "tracks": 0, "playlists": 0, "kv": 0, "other": 0]
        ))) { XCTAssertEqual($0 as? LegacyMigrationValidationError, .invalidCounts) }
    }

    func testProbeRejectsOutOfOrderOversizedAndDuplicatePages() throws {
        let outOfOrder = LegacyMigrationInventoryProbe()
        try outOfOrder.receive(inventory: inventory(albums: 0, tracks: 0, playlists: 0, kv: 0))
        XCTAssertThrowsError(try outOfOrder.receive(page: page(.albums, number: 1))) {
            XCTAssertEqual($0 as? LegacyMigrationValidationError, .pageOutOfOrder)
        }

        let oversized = LegacyMigrationInventoryProbe()
        try oversized.receive(inventory: inventory(albums: 251, tracks: 0, playlists: 0, kv: 0))
        XCTAssertThrowsError(try oversized.receive(page: page(
            .albums,
            ids: (0...250).map { "album-\($0)" }
        ))) { XCTAssertEqual($0 as? LegacyMigrationValidationError, .invalidPage) }

        let duplicate = LegacyMigrationInventoryProbe()
        try duplicate.receive(inventory: inventory(albums: 2, tracks: 0, playlists: 0, kv: 0))
        XCTAssertThrowsError(try duplicate.receive(page: page(.albums, ids: ["same", "same"]))) {
            XCTAssertEqual($0 as? LegacyMigrationValidationError, .duplicateID)
        }
    }

    func testProbeRequiresLastPageCountsToMatchInventory() throws {
        let probe = LegacyMigrationInventoryProbe()
        try probe.receive(inventory: inventory(albums: 2, tracks: 0, playlists: 0, kv: 0))
        XCTAssertThrowsError(try probe.receive(page: page(.albums, ids: ["album-1"]))) {
            XCTAssertEqual($0 as? LegacyMigrationValidationError, .countMismatch)
        }
    }

    func testProbeRejectsBlobOutsideItsOwnerPageAndUnsafeFilename() throws {
        let wrongOwner = LegacyMigrationInventoryProbe()
        try wrongOwner.receive(inventory: inventory(albums: 1, tracks: 0, playlists: 0, kv: 0))
        XCTAssertThrowsError(try wrongOwner.receive(page: page(
            .albums,
            ids: ["album-1"],
            blobs: [blob(ownerID: "album-2", kind: .artwork)]
        ))) { XCTAssertEqual($0 as? LegacyMigrationValidationError, .invalidBlob) }

        let unsafeName = LegacyMigrationInventoryProbe()
        try unsafeName.receive(inventory: inventory(albums: 0, tracks: 1, playlists: 0, kv: 0))
        XCTAssertThrowsError(try unsafeName.receive(page: page(
            .tracks,
            ids: ["track-1"],
            blobs: [blob(ownerID: "track-1", kind: .audio, fileName: "../track.flac")]
        ))) { XCTAssertEqual($0 as? LegacyMigrationValidationError, .invalidBlob) }
    }

    func testProbeRejectsUnsafePathsNegativeSizesAndMismatchedRecords() throws {
        for path in ["/private/track.flac", "Music/../track.flac", "Music//track.flac", "C:\\track.flac"] {
            let probe = LegacyMigrationInventoryProbe()
            try probe.receive(inventory: inventory(albums: 0, tracks: 1, playlists: 0, kv: 0))
            XCTAssertThrowsError(try probe.receive(page: page(
                .tracks,
                ids: ["track-1"],
                records: [[
                    "id": .string("track-1"),
                    "albumId": .string("album-1"),
                    "path": .string(path),
                    "bytes": .number(1)
                ]]
            ))) { XCTAssertEqual($0 as? LegacyMigrationValidationError, .invalidPage) }
        }

        let negative = LegacyMigrationInventoryProbe()
        try negative.receive(inventory: inventory(albums: 0, tracks: 1, playlists: 0, kv: 0))
        XCTAssertThrowsError(try negative.receive(page: page(
            .tracks,
            ids: ["track-1"],
            records: [[
                "id": .string("track-1"),
                "albumId": .string("album-1"),
                "bytes": .number(-1)
            ]]
        ))) { XCTAssertEqual($0 as? LegacyMigrationValidationError, .invalidPage) }

        let mismatch = LegacyMigrationInventoryProbe()
        try mismatch.receive(inventory: inventory(albums: 1, tracks: 0, playlists: 0, kv: 0))
        XCTAssertThrowsError(try mismatch.receive(page: page(
            .albums,
            ids: ["album-1"],
            records: [["id": .string("album-2")]]
        ))) { XCTAssertEqual($0 as? LegacyMigrationValidationError, .invalidPage) }
    }

    func testProbeCannotFinishBeforeEveryStoreEnds() throws {
        let probe = LegacyMigrationInventoryProbe()
        try probe.receive(inventory: inventory(albums: 0, tracks: 0, playlists: 0, kv: 0))
        try probe.receive(page: page(.albums))
        XCTAssertThrowsError(try probe.finishInventory()) {
            XCTAssertEqual($0 as? LegacyMigrationValidationError, .incomplete)
        }
    }

    func testFailureIsBoundedAndTerminal() throws {
        let probe = LegacyMigrationInventoryProbe()
        let completed = expectation(description: "failure delivered")
        probe.onCompletion = { result in
            XCTAssertEqual(try? result.get(), nil)
            if case .failure(let failure) = result {
                XCTAssertEqual(failure.code, "legacy_inventory_failed")
            }
            completed.fulfill()
        }
        try probe.receive(failure: LegacyMigrationFailure(
            code: "legacy_inventory_failed",
            message: "Legacy catalogue unavailable"
        ))
        wait(for: [completed], timeout: 1)
        XCTAssertThrowsError(try probe.receive(failure: LegacyMigrationFailure(code: "again", message: "Again"))) {
            XCTAssertEqual($0 as? LegacyMigrationValidationError, .alreadyFinished)
        }
    }

    private func inventory(albums: Int, tracks: Int, playlists: Int, kv: Int) -> LegacyMigrationInventory {
        LegacyMigrationInventory(
            databaseName: "isolation-db",
            schemaVersion: 1,
            counts: ["albums": albums, "tracks": tracks, "playlists": playlists, "kv": kv]
        )
    }

    private func page(
        _ store: LegacyMigrationStore,
        number: Int = 0,
        ids: [String] = [],
        records: [[String: LegacyJSONValue]]? = nil,
        blobs: [LegacyMigrationBlobDescriptor] = [],
        isLast: Bool = true
    ) -> LegacyMigrationPage {
        let values = records ?? ids.map { id in
            switch store {
            case .albums: return ["id": .string(id)]
            case .tracks: return ["id": .string(id), "albumId": .string("album-1")]
            case .playlists: return ["id": .string(id), "items": .array([])]
            case .kv: return ["k": .string(id)]
            }
        }
        return LegacyMigrationPage(store: store, page: number, ids: ids, records: values, blobs: blobs, isLast: isLast)
    }

    private func blob(
        ownerID: String,
        kind: LegacyMigrationArtifactKind,
        fileName: String = ""
    ) -> LegacyMigrationBlobDescriptor {
        LegacyMigrationBlobDescriptor(
            ownerID: ownerID,
            kind: kind,
            byteLength: 12,
            mediaType: kind == .artwork ? "image/jpeg" : "audio/flac",
            fileName: fileName
        )
    }

    @MainActor
    private func waitForJavaScript(_ script: String, in webView: WKWebView) async throws {
        for _ in 0..<100 {
            if (try? await evaluate(script, in: webView)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Timed out waiting for the Capacitor page")
    }

    @MainActor
    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: value) }
            }
        }
    }

    @MainActor
    @available(iOS 15.0, *)
    private func callAsync(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
    }
}
