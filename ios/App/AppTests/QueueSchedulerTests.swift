import AVFoundation
import XCTest
@testable import App

final class QueueSchedulerTests: XCTestCase {
    private let a = QueueItem(trackID: "a", albumID: "album", mediaRef: .native(relativePath: "a.wav"))
    private let b = QueueItem(trackID: "b", albumID: "album", mediaRef: .native(relativePath: "b.wav"))
    private let c = QueueItem(trackID: "c", albumID: "album", mediaRef: .native(relativePath: "c.wav"))

    func testQueueReplacementInvalidatesPreviouslyPreparedNextTrack() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.prepareCurrent(position: 0)
        let old = scheduler.currentGeneration
        let completion = try XCTUnwrap(graph.schedules.first?.completion)
        try scheduler.replaceQueue([a, c], index: 0, revision: 2)
        completion()
        XCTAssertEqual(scheduler.currentGeneration, old, "Upcoming edits preserve the current schedule")
        XCTAssertEqual(scheduler.preparedNextTrackID, "c")
        XCTAssertEqual(scheduler.currentTrackID, "a")
        XCTAssertEqual(scheduler.queueRevision, 2)
    }

    func testRepeatChangesOnlyFutureScheduleAtMidTrackAndEOF() throws {
        for frame: Int64 in [1100, 2399, 2400] {
            let (scheduler, graph, _) = try makeScheduler([a, b])
            try scheduler.play()
            graph.framesBySlot[.a] = frame
            let generation = scheduler.currentGeneration
            let oldNext = graph.schedules[1].completion
            for mode: RepeatMode in [.all, .one, .off] {
                try scheduler.setRepeatMode(mode)
                XCTAssertEqual(scheduler.currentGeneration, generation)
                XCTAssertEqual(scheduler.currentTrackID, "a")
                XCTAssertEqual(scheduler.currentPosition, Double(frame) / 48000, accuracy: 0.000001)
                XCTAssertTrue(scheduler.isPlaying)
                XCTAssertEqual(graph.schedules.filter { $0.slot == .a }.count, 1)
                XCTAssertEqual(scheduler.preparedNextTrackID, mode == .one ? "a" : "b")
            }
            oldNext() // A discarded alternate-node callback must not complete its replacement.
            XCTAssertEqual(scheduler.currentTrackID, "a")
            graph.schedules[0].completion()
            XCTAssertEqual(scheduler.currentTrackID, "b")
            XCTAssertTrue(scheduler.isPlaying)
        }
    }

    func testFailedFutureRepeatPreparationLeavesCurrentAudioAndPolicyIntact() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b], rejected: .unsupported(reason: "decoder"))
        try scheduler.setRepeatMode(.one)
        try scheduler.play()
        graph.framesBySlot[.a] = 1200
        XCTAssertThrowsError(try scheduler.setRepeatMode(.off))
        XCTAssertTrue(scheduler.isPlaying)
        XCTAssertEqual(scheduler.currentPosition, 0.025, accuracy: 0.000001)
        XCTAssertEqual(graph.schedules.filter { $0.slot == .a }.count, 1)
        // Policy rollback prevents the failed successor from breaking Repeat One's restart.
        try scheduler.seek(seconds: 0)
        XCTAssertEqual(scheduler.preparedNextTrackID, "a")
    }

    func testSeekToDecodedEOFUsesLastPlayableFrameAndRefreshIsSafe() throws {
        let (scheduler, graph, _) = try makeScheduler([a])
        try scheduler.play()
        try scheduler.seek(seconds: 2400.0 / 48000)
        XCTAssertEqual(graph.schedules.last?.sourceFrame, 2399)
        graph.elapsedFrames = 1
        XCTAssertEqual(scheduler.currentPosition, 0.05, accuracy: 0.000001)
        graph.schedules.last?.completion()
        XCTAssertFalse(scheduler.isPlaying)
        XCTAssertEqual(scheduler.currentPosition, 0.05, accuracy: 0.000001)
    }

    func testRepeatOneIsPreparedAtExactBoundaryWithoutRestart() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.play()
        try scheduler.setRepeatMode(.one)
        graph.framesBySlot[.a] = 2400
        graph.schedules[0].completion()
        XCTAssertTrue(scheduler.isPlaying)
        XCTAssertTrue(graph.started)
        XCTAssertEqual(graph.schedules.last?.sourceFrame, 0)
        XCTAssertEqual(graph.schedules.last?.outputFrame, 4800)
        XCTAssertEqual(scheduler.currentIndex, 0)
        XCTAssertEqual(scheduler.preparedNextTrackID, "a")
    }

    func testRepeatAllPreparesWrapBeforeFinalItemCompletes() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b, c])
        try scheduler.setRepeatMode(.all)
        try scheduler.play()
        graph.schedules[0].completion()
        XCTAssertEqual(scheduler.currentTrackID, "b")
        graph.schedules[1].completion()
        XCTAssertEqual(scheduler.currentTrackID, "c")
        XCTAssertEqual(scheduler.preparedNextTrackID, "a")
        XCTAssertEqual(graph.schedules.last?.outputFrame, 7200)
        graph.schedules[2].completion()
        XCTAssertEqual(scheduler.currentIndex, 0)
        XCTAssertTrue(scheduler.isPlaying)
        XCTAssertEqual(graph.schedules.map(\.outputFrame), [0, 2400, 4800, 7200, 9600])
    }

    func testUpcomingReorderPreservesLiveNodeAndPreparedSuccessor() throws {
        let d = QueueItem(trackID: "d", albumID: "album", mediaRef: .native(relativePath: "d.wav"))
        for playing in [false, true] {
            let (scheduler, graph, _) = try makeScheduler([a, b, c, d])
            try scheduler.prepareCurrent(position: 1000.0 / 48000)
            if playing { try scheduler.play() }
            let generation = scheduler.currentGeneration
            let position = scheduler.currentPosition
            try scheduler.replaceQueue([a, d, b, c], index: 0, revision: 2)
            XCTAssertEqual(scheduler.queueItems.map(\.trackID), ["a", "d", "b", "c"])
            XCTAssertEqual(scheduler.currentGeneration, generation)
            XCTAssertEqual(scheduler.currentPosition, position, accuracy: 0.000001)
            XCTAssertEqual(scheduler.currentIndex, 0)
            XCTAssertEqual(scheduler.isPlaying, playing)
            XCTAssertEqual(scheduler.preparedNextTrackID, "d")
            XCTAssertEqual(graph.schedules.filter { $0.slot == .a }.count, 1)
            try scheduler.replaceQueue([a, b, c, d], index: 0, revision: 3)
            XCTAssertEqual(scheduler.preparedNextTrackID, "b")
            XCTAssertEqual(scheduler.currentGeneration, generation)
        }
    }

    func testReorderedSuccessorIsTheActualHandoffAndUnchangedNextIsRetained() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b, c])
        try scheduler.play()
        graph.framesBySlot[.a] = 2399
        let firstCompletion = graph.schedules[0].completion
        try scheduler.replaceQueue([a, c, b], index: 0, revision: 2)
        XCTAssertEqual(scheduler.preparedNextTrackID, "c")
        XCTAssertEqual(scheduler.currentPosition, 2399.0 / 48000, accuracy: 0.000001)
        let scheduleCount = graph.schedules.count
        try scheduler.replaceQueue([a, c], index: 0, revision: 3)
        XCTAssertEqual(graph.schedules.count, scheduleCount, "Removing a later item keeps the same prepared successor")
        firstCompletion()
        XCTAssertEqual(scheduler.currentTrackID, "c")
        XCTAssertEqual(scheduler.currentIndex, 1)
        XCTAssertTrue(scheduler.isPlaying)
    }

    func testNextIsScheduledAtExactOutputBoundaryBeforePlaybackStarts() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.prepareCurrent(position: 0)
        XCTAssertFalse(graph.started)
        XCTAssertEqual(graph.schedules.map { $0.slot }, [.a, .b])
        XCTAssertEqual(graph.schedules.map { $0.outputFrame }, [0, 2400])
        try scheduler.play()
        XCTAssertTrue(scheduler.isPlaying)
        XCTAssertTrue(graph.started)
        XCTAssertEqual(graph.schedules.count, 2)
    }

    func testReplayGainIsAppliedToEveryPreparedSlot() throws {
        let graph = RecordingGraph()
        let resolver = FixtureResolver()
        let gains: [String: ReplayGainValues] = [
            "a.wav": .init(trackGainDB: -6, albumGainDB: nil, trackPeak: nil, albumPeak: nil),
            "b.wav": .init(trackGainDB: -3, albumGainDB: nil, trackPeak: nil, albumPeak: nil)
        ]
        let scheduler = QueueScheduler(graph: graph, resolver: resolver) { url in
            .playable(ProbedMedia(
                url: url,
                descriptor: SourceFormatDescriptor(
                    codec: "pcm", container: "wav", sampleRate: 48_000,
                    channelCount: 2, bitDepth: 16, duration: 1,
                    replayGain: gains[url.lastPathComponent]
                ),
                frameCount: 2_400
            ))
        }
        scheduler.setReplayGain(mode: .track, preampDB: 0)
        try scheduler.setQueue([a, b], index: 0, revision: 1)
        try scheduler.prepareCurrent(position: 0)

        XCTAssertEqual(try XCTUnwrap(graph.replayGain[.a]), Float(pow(10, -6.0 / 20.0)), accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(graph.replayGain[.b]), Float(pow(10, -3.0 / 20.0)), accuracy: 0.00001)
    }

    func testHandoffFlipsSlotsAndPreparesFollowingWithoutAnotherPlayCommand() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b, c])
        try scheduler.play()
        let first = graph.schedules[0].completion
        first()
        XCTAssertEqual(scheduler.currentTrackID, "b") // Drains serialized completion.
        XCTAssertEqual(scheduler.currentSlot, .b)
        XCTAssertEqual(scheduler.preparedNextTrackID, "c")
        XCTAssertEqual(graph.schedules.last?.slot, .a)
        XCTAssertEqual(graph.schedules.last?.outputFrame, 4800)
        first() // A duplicated callback from this generation must also be harmless.
        XCTAssertEqual(scheduler.currentTrackID, "b")
    }

    func testRapidSkipAndPreviousRejectAllObsoleteCompletions() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b, c])
        try scheduler.play()
        let staleA = graph.schedules[0].completion
        try scheduler.next()
        let staleB = graph.schedules[2].completion
        try scheduler.next()
        staleA()
        staleB()
        XCTAssertEqual(scheduler.currentTrackID, "c")
        try scheduler.previous()
        XCTAssertEqual(scheduler.currentTrackID, "b")
        XCTAssertTrue(scheduler.isPlaying)
    }

    func testSeekCancelsOldScheduleAndUsesRemainingDecodedFrames() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.play()
        let stale = graph.schedules[0].completion
        try scheduler.seek(seconds: 1000.0 / 48000)
        stale()
        XCTAssertEqual(scheduler.currentTrackID, "a")
        XCTAssertEqual(graph.schedules.suffix(2).map { $0.sourceFrame }, [1000, 0])
        XCTAssertEqual(graph.schedules.last?.outputFrame, 1400)
        XCTAssertTrue(scheduler.isPlaying)
    }

    func testPauseAtPendingHandoffPromotesNextBeforeRetainingPosition() throws {
        for elapsed in [Int64(2400), 2500] {
            let (scheduler, graph, _) = try makeScheduler([a, b, c])
            try scheduler.play()
            let stale = graph.schedules[0].completion
            graph.framesBySlot = [.a: elapsed, .b: 37]
            scheduler.pause()
            XCTAssertEqual(scheduler.currentTrackID, "b")
            XCTAssertFalse(scheduler.isPlaying)
            try scheduler.play()
            stale()
            XCTAssertEqual(scheduler.currentTrackID, "b")
            XCTAssertEqual(graph.schedules.suffix(2).first?.sourceFrame, 37)
            XCTAssertEqual(scheduler.preparedNextTrackID, "c")
        }
    }

    func testSameCurrentReplacementAtPendingHandoffUsesReplacementSuccessor() throws {
        for elapsed in [Int64(2400), 2500] {
            let (scheduler, graph, _) = try makeScheduler([a, b])
            try scheduler.play()
            let stale = graph.schedules[0].completion
            graph.framesBySlot = [.a: elapsed, .b: 37]
            try scheduler.replaceQueue([a, c], index: 0, revision: 2)
            stale()
            XCTAssertEqual(scheduler.currentTrackID, "c")
            XCTAssertEqual(scheduler.queueRevision, 2)
            XCTAssertEqual(graph.schedules.last?.sourceFrame, 0)
            XCTAssertTrue(scheduler.isPlaying)
        }
    }

    func testSameCurrentReplacementRetainsPromotedSuccessorFrame() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.play()
        graph.framesBySlot = [.a: 2400, .b: 37]
        try scheduler.replaceQueue([a, b, c], index: 0, revision: 2)
        XCTAssertEqual(scheduler.currentTrackID, "b")
        XCTAssertEqual(scheduler.currentPosition, 37.0 / 48000, accuracy: 0.000001)
        XCTAssertEqual(graph.schedules.filter { $0.slot == .b }.count, 1, "The already playing successor must not reopen")
        XCTAssertEqual(graph.schedules.suffix(2).first?.sourceFrame, 0)
        XCTAssertEqual(scheduler.preparedNextTrackID, "c")
    }

    func testPauseAtPendingTerminalCompletionRestartsOnlyOnExplicitPlay() throws {
        let (scheduler, graph, _) = try makeScheduler([a])
        try scheduler.play()
        let stale = graph.schedules[0].completion
        graph.framesBySlot = [.a: 2500]
        scheduler.pause()
        stale()
        XCTAssertFalse(scheduler.isPlaying)
        try scheduler.play()
        XCTAssertEqual(scheduler.currentTrackID, "a")
        XCTAssertEqual(graph.schedules.last?.sourceFrame, 0)
        XCTAssertTrue(scheduler.isPlaying)
    }

    func testSameCurrentReplacementAtTerminalEOFDoesNotReplayAutomatically() throws {
        let (scheduler, graph, _) = try makeScheduler([a])
        try scheduler.play()
        let stale = graph.schedules[0].completion
        graph.framesBySlot = [.a: 2400]
        try scheduler.replaceQueue([a], index: 0, revision: 2)
        stale()
        XCTAssertFalse(scheduler.isPlaying)
        XCTAssertEqual(graph.schedules.count, 1)
        try scheduler.play()
        XCTAssertEqual(graph.schedules.last?.sourceFrame, 0)
    }

    func testReplacementRemovingSuccessorAtPendingHandoffRetainsTerminalState() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.play()
        graph.framesBySlot = [.a: 2400, .b: 37]
        try scheduler.replaceQueue([a], index: 0, revision: 2)
        XCTAssertEqual(scheduler.currentTrackID, "a")
        XCTAssertFalse(scheduler.isPlaying)
        try scheduler.play()
        XCTAssertEqual(graph.schedules.last?.sourceFrame, 0)
    }

    func testPauseResumeReanchorsBothSlotsAndPreservesPosition() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.play()
        let stale = graph.schedules[0].completion
        graph.elapsedFrames = 1000
        scheduler.pause()
        stale()
        XCTAssertFalse(scheduler.isPlaying)
        try scheduler.play()
        XCTAssertEqual(graph.schedules.suffix(2).map { $0.sourceFrame }, [1000, 0])
        XCTAssertEqual(graph.schedules.last?.outputFrame, 1400)
    }

    func testInvalidationStopsPreparedPlayersAndRejectsCallbacks() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.play()
        let callback = graph.schedules[0].completion
        scheduler.invalidatePendingSchedule()
        callback()
        XCTAssertEqual(scheduler.currentTrackID, "a")
        XCTAssertNil(scheduler.preparedNextTrackID)
        XCTAssertFalse(scheduler.isPlaying)
        XCTAssertFalse(graph.started)
    }

    func testCompletedEventIsEmittedOnlyOnceAndEndsPlayback() throws {
        let (scheduler, graph, _) = try makeScheduler([a])
        let completed = expectation(description: "completed once")
        completed.assertForOverFulfill = true
        scheduler.onEvent = { if case .completed = $0 { completed.fulfill() } }
        try scheduler.play()
        graph.schedules[0].completion()
        graph.schedules[0].completion()
        XCTAssertFalse(scheduler.isPlaying)
        wait(for: [completed], timeout: 1)
        XCTAssertNil(scheduler.preparedNextTrackID)
    }

    func testUnplayableNextIsReportedAndNeverSilentlySkipped() throws {
        let capabilities: [MediaCapability] = [.unsupported(reason: "decoder"), .decodeFailed(reason: "corrupt"), .unavailable]
        for capability in capabilities {
            let (scheduler, graph, _) = try makeScheduler([a, b, c], rejected: capability)
            let failed = expectation(description: "explicit media failure")
            scheduler.onEvent = { event in
                if case .failed(_, let error, _) = event {
                    XCTAssertEqual(error, .media(trackID: "b", capability: capability))
                    failed.fulfill()
                }
            }
            XCTAssertThrowsError(try scheduler.play())
            wait(for: [failed], timeout: 1)
            XCTAssertEqual(scheduler.currentTrackID, "a")
            XCTAssertNil(scheduler.preparedNextTrackID)
            XCTAssertFalse(graph.started)
        }
    }

    func testUnavailableCurrentTrackFailsExplicitlyWithoutStartingTheEngine() throws {
        let graph = RecordingGraph()
        let scheduler = QueueScheduler(graph: graph, resolver: FixtureResolver()) { _ in .unavailable }
        let failed = expectation(description: "current media failure")
        scheduler.onEvent = { event in
            guard case .failed(let trackID, let error, _) = event else { return }
            XCTAssertEqual(trackID, "a")
            XCTAssertEqual(error, .media(trackID: "a", capability: .unavailable))
            failed.fulfill()
        }
        try scheduler.setQueue([a], index: 0, revision: 1)

        XCTAssertThrowsError(try scheduler.play()) { error in
            XCTAssertEqual(error as? QueueSchedulerError, .media(trackID: "a", capability: .unavailable))
        }
        wait(for: [failed], timeout: 1)
        XCTAssertEqual(scheduler.currentTrackID, "a")
        XCTAssertNil(scheduler.preparedNextTrackID)
        XCTAssertFalse(graph.started)
    }

    func testReleaseResolvedMediaOnReplacementAndFailure() throws {
        let (scheduler, _, resolver) = try makeScheduler([a, b])
        try scheduler.prepareCurrent(position: 0)
        try scheduler.replaceQueue([c], index: 0, revision: 2)
        XCTAssertEqual(resolver.released.map { $0.lastPathComponent }, ["a.wav", "b.wav"])
        scheduler.invalidatePendingSchedule()
        XCTAssertEqual(resolver.released.last?.lastPathComponent, "c.wav")
    }

    func testInvalidQueueAndSeekInputsAreRejected() throws {
        let (scheduler, _, _) = try makeScheduler([a])
        XCTAssertThrowsError(try scheduler.setQueue([a], index: 1, revision: 2))
        for position in [-1, Double.nan, Double.infinity, 1] {
            XCTAssertThrowsError(try scheduler.seek(seconds: position))
        }
        try scheduler.setQueue([], index: 0, revision: 3)
        XCTAssertNil(scheduler.currentTrackID)
        XCTAssertThrowsError(try scheduler.play())
    }

    func testExactPCMFixtureBoundaryHasZeroInsertedOrDuplicatedFrames() throws {
        let left = try pcm("gapless-a")
        let right = try pcm("gapless-b")
        XCTAssertEqual(left.count, 2400)
        XCTAssertEqual(right.count, 2400)
        let boundary = try QueueScheduler.outputBoundary(start: 0, sourceFrames: Int64(left.count), sourceRate: 48000, outputRate: 48000)
        XCTAssertEqual(boundary, 2400)
        var rendered = [Int16](repeating: 0, count: Int(boundary) + right.count)
        rendered.replaceSubrange(0..<left.count, with: left)
        rendered.replaceSubrange(Int(boundary)..<rendered.count, with: right)
        let expected = (0..<4800).map { frame in
            Int16((8192 * sin(2 * Double.pi * 440 * Double(frame) / 48000)).rounded(.toNearestOrEven))
        }
        XCTAssertEqual(rendered, expected) // Exact samples, 0 inserted / 0 duplicated PCM frames.
        XCTAssertEqual(try QueueScheduler.outputBoundary(start: 900, sourceFrames: 44100, sourceRate: 44100, outputRate: 48000), 48900)
        XCTAssertThrowsError(try QueueScheduler.outputBoundary(start: Int64.max, sourceFrames: 1, sourceRate: 48000, outputRate: 48000))
    }

    func testOutOfOrderNodeCompletionsDoNotLoseQueueCompletion() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.play()
        graph.schedules[1].completion()
        graph.schedules[0].completion()
        XCTAssertEqual(scheduler.currentTrackID, "b")
        XCTAssertFalse(scheduler.isPlaying)
    }

    func testOpeningNextFileFailureClosesCurrentAndReportsNextTrack() throws {
        let (scheduler, graph, resolver) = try makeScheduler([a, b, c])
        graph.failingFile = "b.wav"
        XCTAssertThrowsError(try scheduler.play()) { error in
            guard let failure = error as? QueueSchedulerError,
                  case .operation(let trackID, _) = failure else {
                return XCTFail("Expected operation failure")
            }
            XCTAssertEqual(trackID, "b")
        }
        XCTAssertFalse(scheduler.isPlaying)
        XCTAssertNil(scheduler.preparedNextTrackID)
        XCTAssertEqual(Set(resolver.released.map { $0.lastPathComponent }), Set(["a.wav", "b.wav"]))
    }

    func testResumeRetainsExactFrameWithoutFloatingPointRoundTrip() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b])
        try scheduler.play()
        graph.elapsedFrames = 27 // 27 / 48000 * 48000 can round below 27.
        scheduler.pause()
        try scheduler.play()
        XCTAssertEqual(graph.schedules.suffix(2).first?.sourceFrame, 27)
    }

    func testPreparationFailureAfterHandoffStopsAndReportsFollowingTrack() throws {
        let (scheduler, graph, _) = try makeScheduler([a, b, c])
        try scheduler.play()
        graph.failingFile = "c.wav"
        graph.schedules[0].completion()
        XCTAssertEqual(scheduler.currentTrackID, "b")
        XCTAssertFalse(scheduler.isPlaying)
        XCTAssertNil(scheduler.preparedNextTrackID)
    }

    func testPlaybackCanRestartAfterFinalCompletion() throws {
        let (scheduler, graph, _) = try makeScheduler([a])
        try scheduler.play()
        graph.schedules[0].completion()
        XCTAssertFalse(scheduler.isPlaying)
        try scheduler.play()
        XCTAssertTrue(scheduler.isPlaying)
        XCTAssertEqual(graph.schedules.last?.sourceFrame, 0)
    }

    /// Device integration gate: run explicitly on an idle 48 kHz output route.
    /// This exercises real AVAudioPlayerNodes and captures the actual program output.
    /// The pure PCM test above remains available without audio hardware.
    func testDeviceCaptureGaplessWAVHasExactBoundary() throws {
        guard ProcessInfo.processInfo.environment["AEON_RUN_AUDIO_CAPTURE"] == "1" else {
            throw XCTSkip("Set AEON_RUN_AUDIO_CAPTURE=1 on a device/simulator with a 48 kHz audio route")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setPreferredSampleRate(48000)
        try session.setActive(true)
        defer { try? session.setActive(false) }
        let graph = AudioEngineGraph()
        try graph.configure()
        guard try graph.schedulingSampleRate() == 48000 else {
            throw XCTSkip("Exact PCM gate requires a 48 kHz route; no codec/SRC tolerance is claimed")
        }
        let resolver = BundleResolver(bundle: Bundle(for: Self.self))
        let scheduler = QueueScheduler(graph: graph, resolver: resolver)
        let tracks = ["gapless-a", "gapless-b"].map {
            QueueItem(trackID: $0, albumID: "continuous", mediaRef: .native(relativePath: $0 + ".wav"))
        }
        let captured = expectation(description: "continuous PCM captured")
        let lock = NSLock()
        var samples: [Int16] = []
        var captureComplete = false
        graph.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let values = (0..<Int(buffer.frameLength)).map { frame in
                Int16(max(-32768, min(32767, (Double(channel[frame]) * 32768).rounded())))
            }
            lock.lock()
            if !captureComplete {
                samples.append(contentsOf: values)
                if let first = samples.firstIndex(where: { $0 != 0 }), first > 0,
                   samples.count >= first - 1 + 4800 {
                    captureComplete = true
                    captured.fulfill()
                }
            }
            lock.unlock()
        }
        defer {
            scheduler.invalidatePendingSchedule()
            graph.engine.mainMixerNode.removeTap(onBus: 0)
            graph.stop()
        }
        try scheduler.setQueue(tracks, index: 0, revision: 1)
        try scheduler.play()
        wait(for: [captured], timeout: 5)
        lock.lock()
        let output = samples
        lock.unlock()
        let first = try XCTUnwrap(output.firstIndex(where: { $0 != 0 }))
        XCTAssertGreaterThan(first, 0)
        guard first > 0, output.count >= first - 1 + 4800 else { return XCTFail("Incomplete PCM capture") }
        let expected = try pcm("gapless-a") + pcm("gapless-b")
        XCTAssertEqual(Array(output[(first - 1)..<(first - 1 + 4800)]), expected)
    }

    private func pcm(_ name: String) throws -> [Int16] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "wav", subdirectory: "audio"))
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.int16ChannelData)[0], count: Int(buffer.frameLength)))
    }

    private func makeScheduler(_ items: [QueueItem], rejected: MediaCapability? = nil) throws -> (QueueScheduler, RecordingGraph, FixtureResolver) {
        let graph = RecordingGraph()
        let resolver = FixtureResolver()
        let scheduler = QueueScheduler(graph: graph, resolver: resolver, probe: { url in
            if url.lastPathComponent == "b.wav", let rejected { return rejected }
            return .playable(ProbedMedia(url: url, descriptor: SourceFormatDescriptor(codec: "pcm", container: "wav", sampleRate: 48000, channelCount: 2, bitDepth: 16, duration: 2400.0 / 48000), frameCount: 2400))
        })
        try scheduler.setQueue(items, index: 0, revision: 1)
        return (scheduler, graph, resolver)
    }
}

private final class FixtureResolver: MediaResolving {
    var released: [URL] = []
    func resolve(_ reference: MediaReference) throws -> URL {
        guard case .native(let path) = reference else { throw MediaStoreError.invalidBookmark }
        return URL(fileURLWithPath: "/fixtures/\(path)")
    }
    func release(_ url: URL) { released.append(url) }
}

private final class RecordingGraph: QueueSchedulingGraph {
    struct Schedule {
        let slot: AudioSlot
        let sourceFrame: Int64
        let outputFrame: Int64
        let completion: () -> Void
    }
    var schedules: [Schedule] = []
    var started = false
    var elapsedFrames: Int64 = 0
    var framesBySlot: [AudioSlot: Int64] = [:]
    var failingFile: String?
    var replayGain: [AudioSlot: Float] = [:]
    func schedulingSampleRate() throws -> Double { 48000 }
    func openForScheduling(url: URL, slot: AudioSlot) throws -> ScheduledAudioFile {
        if url.lastPathComponent == failingFile { throw MediaStoreError.verificationFailed }
        return ScheduledAudioFile(frameCount: 2400, sampleRate: 48000)
    }
    func schedule(slot: AudioSlot, sourceFrame: Int64, outputFrame: Int64, completion: @escaping () -> Void) throws {
        schedules.append(Schedule(slot: slot, sourceFrame: sourceFrame, outputFrame: outputFrame, completion: completion))
    }
    func startScheduledPlayback() throws { started = true }
    func elapsedSourceFrames(slot: AudioSlot) -> Int64? { framesBySlot[slot] ?? elapsedFrames }
    func cancelScheduledPlayback() { started = false; elapsedFrames = 0; framesBySlot.removeAll() }
    func closeScheduledFile(slot: AudioSlot) {}
    func setReplayGain(_ scalar: Float, slot: AudioSlot) { replayGain[slot] = scalar }
}

private final class BundleResolver: MediaResolving {
    let bundle: Bundle
    init(bundle: Bundle) { self.bundle = bundle }
    func resolve(_ reference: MediaReference) throws -> URL {
        guard case .native(let path) = reference,
              let url = bundle.url(forResource: path, withExtension: nil, subdirectory: "audio") else {
            throw MediaStoreError.verificationFailed
        }
        return url
    }
}
