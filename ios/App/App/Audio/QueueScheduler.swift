import Foundation

struct ScheduleToken: Equatable {
    let generation: UInt64
}

enum SchedulerEvent {
    case started(trackID: String, index: Int, token: ScheduleToken)
    case handoff(fromTrackID: String, toTrackID: String, index: Int, token: ScheduleToken)
    case completed(trackID: String, token: ScheduleToken)
    case failed(trackID: String?, error: QueueSchedulerError, token: ScheduleToken)
}

enum QueueSchedulerError: Error, Equatable {
    case emptyQueue
    case invalidQueueIndex(Int)
    case invalidPosition
    case invalidAudioFormat
    case timelineOverflow
    case media(trackID: String, capability: MediaCapability)
    case operation(trackID: String?, reason: String)

    enum PreparationStage: String {
        case fileAccess = "file_access", graphSetup = "graph_setup"
        case decoderOpen = "decoder_open", scheduling, playbackOperation = "playback_operation"
    }

    static func preparation(_ stage: PreparationStage, trackID: String?, error: Error) -> QueueSchedulerError {
        if let existing = error as? QueueSchedulerError { return existing }
        let native = error as NSError
        // Never carry localized descriptions/userInfo: either can include a personal path.
        let domain = native.domain.range(of: #"^[A-Za-z0-9_.-]{1,100}$"#, options: .regularExpression) != nil
            ? native.domain : "NativeError"
        return .operation(trackID: trackID, reason: "\(stage.rawValue):\(domain):\(native.code)")
    }
}

struct ScheduledAudioFile {
    let frameCount: Int64
    let sampleRate: Double
}

/// All calls are confined to the scheduler queue. Completions may arrive on any queue.
protocol QueueSchedulingGraph: AnyObject {
    func schedulingSampleRate() throws -> Double
    func openForScheduling(url: URL, slot: AudioSlot) throws -> ScheduledAudioFile
    func schedule(slot: AudioSlot, sourceFrame: Int64, outputFrame: Int64, completion: @escaping () -> Void) throws
    func startScheduledPlayback() throws
    func elapsedSourceFrames(slot: AudioSlot) -> Int64?
    func cancelScheduledPlayback()
    func closeScheduledFile(slot: AudioSlot)
    func setReplayGain(_ scalar: Float, slot: AudioSlot)
}

extension QueueSchedulingGraph {
    func setReplayGain(_ scalar: Float, slot: AudioSlot) {}
}

final class QueueScheduler {
    private struct Prepared {
        let id: UUID
        let index: Int
        let slot: AudioSlot
        let url: URL
        let file: ScheduledAudioFile
        let sourceFrame: Int64
        let endOutputFrame: Int64
        let sourceFormat: SourceFormatDescriptor
    }

    private let graph: QueueSchedulingGraph
    private let resolver: MediaResolving
    private let probe: (URL) -> MediaCapability
    private let serialization = DispatchQueue(label: "app.aeon.audio.queue-scheduler")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var items: [QueueItem] = []
    private var index: Int?
    private var revision: UInt64 = 0
    private var generation: UInt64 = 0
    private var slot: AudioSlot = .a
    private var current: Prepared?
    private var following: Prepared?
    private var position: Double = 0
    private var retainedSourceFrame: Int64?
    private var playing = false
    private var outputRate: Double = 0
    private var earlyCompletions: Set<Int> = []
    private var reachedEnd = false
    private var eventHandler: ((SchedulerEvent) -> Void)?
    private var replayGainMode: ReplayGainMode = .off
    private var replayGainPreampDB: Double = 0
    private var repeatMode: RepeatMode = .off

    /// Events arrive on the main queue, outside the scheduling serialization domain.
    var onEvent: ((SchedulerEvent) -> Void)? {
        get { confined { eventHandler } }
        set { confined { eventHandler = newValue } }
    }
    var currentGeneration: UInt64 { confined { generation } }
    var queueRevision: UInt64 { confined { revision } }
    var queueItems: [QueueItem] { confined { items } }
    var currentIndex: Int? { confined { index } }
    var currentSlot: AudioSlot { confined { slot } }
    var currentTrackID: String? { confined { index.map { items[$0].trackID } } }
    var currentSourceFormat: SourceFormatDescriptor? { confined { current?.sourceFormat } }
    var preparedNextTrackID: String? { confined { following.map { items[$0.index].trackID } } }
    var isPlaying: Bool { confined { playing } }
    var currentPosition: Double {
        confined {
            guard let current else { return position }
            guard playing else { return position }
            let elapsed = max(0, graph.elapsedSourceFrames(slot: current.slot) ?? 0)
            let remaining = max(0, current.file.frameCount - current.sourceFrame)
            let frame = current.sourceFrame + min(elapsed, remaining)
            return Double(frame) / current.file.sampleRate
        }
    }

    init(graph: QueueSchedulingGraph, resolver: MediaResolving, probe: @escaping (URL) -> MediaCapability) {
        self.graph = graph
        self.resolver = resolver
        self.probe = probe
        serialization.setSpecific(key: queueKey, value: 1)
    }

    convenience init(graph: AudioEngineGraph, resolver: MediaResolving, probe: MetadataProbe = MetadataProbe()) {
        self.init(graph: graph, resolver: resolver, probe: probe.probe(url:))
    }

    deinit {
        // Pending completions hold only a weak scheduler reference.
        graph.cancelScheduledPlayback()
        if let current { graph.closeScheduledFile(slot: current.slot); resolver.release(current.url) }
        if let following { graph.closeScheduledFile(slot: following.slot); resolver.release(following.url) }
    }

    func setQueue(_ items: [QueueItem], index: Int, revision: UInt64) throws {
        try confined {
            try validate(items: items, index: index)
            invalidate()
            self.items = items
            self.index = items.isEmpty ? nil : index
            self.revision = revision
            position = 0
            retainedSourceFrame = nil
            reachedEnd = false
            slot = .a
        }
    }

    func prepareCurrent(position: Double) throws {
        try confined { try performing { try prepare(position: position) } }
    }

    func play() throws {
        try confined {
            guard !playing else { return }
            try performing {
                if current == nil {
                    try prepare(position: reachedEnd ? 0 : position, exactFrame: reachedEnd ? nil : retainedSourceFrame)
                }
                try start()
            }
        }
    }

    func pause() {
        confined {
            capturePosition()
            invalidate()
        }
    }

    func seek(seconds: Double) throws {
        try confined {
            let resume = playing
            try performing {
                try prepare(position: seconds)
                if resume { try start() }
            }
        }
    }

    func next() throws { try move(by: 1) }
    func previous() throws { try move(by: -1) }

    func replaceQueue(_ items: [QueueItem], index: Int, revision: UInt64) throws {
        try confined {
            try validate(items: items, index: index)
            let previousIndex = self.index
            let sameSelection = !items.isEmpty && previousIndex.map { self.items[$0] == items[index] } == true
            let resume = playing
            capturePosition()
            // An edit of the selected item must not replay it when its native
            // timeline has already crossed EOF but its callback is still pending.
            let consumed = sameSelection ? (self.index ?? 0) - (previousIndex ?? 0) + (reachedEnd ? 1 : 0) : 0
            let liveID = self.index.map { self.items[$0].id }
            let reconciledIndex = sameSelection && !reachedEnd
                ? items.firstIndex(where: { $0.id == liveID }) : nil
            let replacementIndex = reconciledIndex ?? max(0, index + consumed)
            let terminal = sameSelection && replacementIndex >= items.count
            let selectedIndex = items.isEmpty ? 0 : min(replacementIndex, items.count - 1)
            let preserveFrame = !items.isEmpty && !terminal && !reachedEnd &&
                self.index.map { self.items[$0] == items[selectedIndex] } == true
            // Upcoming-only edits keep the live node, timeline and playback intent intact.
            if preserveFrame, let current, current.index == selectedIndex,
               Array(self.items.prefix(selectedIndex + 1)) == Array(items.prefix(selectedIndex + 1)) {
                let desiredNext = Self.successor(after: selectedIndex, count: items.count, mode: repeatMode).map { items[$0] }
                let keepFollowing = following.map { self.items[$0.index] == desiredNext } ?? false
                if !keepFollowing { discardFollowing() }
                self.items = items
                self.index = selectedIndex
                self.revision = revision
                if !keepFollowing { try prepareFollowing() }
                return
            }
            let retainedPosition = preserveFrame ? position : 0
            let exactFrame = preserveFrame ? retainedSourceFrame : nil
            try setQueue(items, index: selectedIndex, revision: revision)
            if items.isEmpty { return }
            if terminal {
                reachedEnd = true
                return // Only a later explicit play restarts a completed queue.
            }
            try performing {
                try prepare(position: retainedPosition, exactFrame: exactFrame)
                if resume { try start() }
            }
        }
    }

    func invalidatePendingSchedule() {
        confined {
            capturePosition()
            invalidate()
        }
    }

    func setReplayGain(mode: ReplayGainMode, preampDB: Double) {
        confined {
            replayGainMode = mode
            replayGainPreampDB = preampDB.isFinite ? preampDB : 0
            applyReplayGain(to: current)
            applyReplayGain(to: following)
        }
    }

    func setRepeatMode(_ mode: RepeatMode) throws {
        try confined {
            guard repeatMode != mode else { return }
            let previousMode = repeatMode
            repeatMode = mode
            // Policy applies to the next boundary. Never stop, seek or reschedule
            // the current node merely because the user changed Repeat.
            if let current {
                let desired = Self.successor(after: current.index, count: items.count, mode: mode)
                if following?.index != desired { discardFollowing() }
            }
            if current != nil, following == nil {
                do { try prepareFollowing() }
                catch { repeatMode = previousMode; throw error }
            }
        }
    }

    /// Convert decoded source frames to the shared output frame timeline. Equal-rate
    /// WAVs use integer addition: no duration metadata or floating point rounding.
    static func outputBoundary(start: Int64, sourceFrames: Int64, sourceRate: Double, outputRate: Double) throws -> Int64 {
        guard start >= 0, sourceFrames >= 0, sourceRate.isFinite, sourceRate > 0,
              outputRate.isFinite, outputRate > 0 else { throw QueueSchedulerError.invalidAudioFormat }
        let frames: Int64
        if sourceRate == outputRate {
            frames = sourceFrames
        } else {
            let converted = (Double(sourceFrames) * outputRate / sourceRate).rounded()
            guard converted.isFinite, converted >= 0, converted < Double(Int64.max) else {
                throw QueueSchedulerError.timelineOverflow
            }
            frames = Int64(converted)
        }
        let (end, overflow) = start.addingReportingOverflow(frames)
        guard !overflow else { throw QueueSchedulerError.timelineOverflow }
        return end
    }

    private func confined<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try body() }
        return try serialization.sync(execute: body)
    }

    private func validate(items: [QueueItem], index: Int) throws {
        guard (items.isEmpty && index == 0) || items.indices.contains(index) else {
            throw QueueSchedulerError.invalidQueueIndex(index)
        }
    }

    private func move(by offset: Int) throws {
        try confined {
            guard let index else { throw QueueSchedulerError.emptyQueue }
            let destination = index + offset
            guard items.indices.contains(destination) else { return }
            let resume = playing
            invalidate()
            self.index = destination
            position = 0
            try performing {
                try prepare(position: 0)
                if resume { try start() }
            }
        }
    }

    private func prepare(position: Double, exactFrame: Int64? = nil) throws {
        guard position.isFinite, position >= 0 else { throw QueueSchedulerError.invalidPosition }
        guard let index else { throw QueueSchedulerError.emptyQueue }
        invalidate()
        slot = .a
        reachedEnd = false
        self.position = position
        retainedSourceFrame = exactFrame
        do { outputRate = try graph.schedulingSampleRate() }
        catch { throw QueueSchedulerError.preparation(.graphSetup, trackID: items[index].trackID, error: error) }
        guard outputRate.isFinite, outputRate > 0 else { throw QueueSchedulerError.invalidAudioFormat }
        current = try prepareItem(index: index, slot: slot, position: position, outputFrame: 0, exactFrame: exactFrame)
        if let current { self.position = min(position, Double(current.file.frameCount) / current.file.sampleRate) }
        try prepareFollowing()
    }

    private func prepareItem(index: Int, slot: AudioSlot, position: Double, outputFrame: Int64, exactFrame: Int64? = nil) throws -> Prepared {
        let item = items[index]
        let url: URL
        do { url = try resolver.resolve(item.mediaRef) }
        catch { throw QueueSchedulerError.preparation(.fileAccess, trackID: item.trackID, error: error) }
        var stage = QueueSchedulerError.PreparationStage.decoderOpen
        do {
            let capability = probe(url)
            guard case .playable(let media) = capability else { throw QueueSchedulerError.media(trackID: item.trackID, capability: capability) }
            // The opened decoder's frame length/rate are authoritative, not metadata duration.
            let file = try graph.openForScheduling(url: url, slot: slot)
            guard file.frameCount > 0, file.sampleRate.isFinite, file.sampleRate > 0 else {
                throw QueueSchedulerError.invalidAudioFormat
            }
            // The display can equal duration; a playable decoder frame must be < frameCount.
            let sourceFrame: Int64
            if let exactFrame {
                guard exactFrame >= 0, exactFrame <= file.frameCount else { throw QueueSchedulerError.invalidPosition }
                sourceFrame = min(exactFrame, file.frameCount - 1)
            } else {
                let requested = (position * file.sampleRate).rounded(.down)
                guard requested.isFinite, requested >= 0, requested <= Double(file.frameCount),
                      requested < Double(Int64.max) else { throw QueueSchedulerError.invalidPosition }
                sourceFrame = min(Int64(requested), file.frameCount - 1)
            }
            let end = try Self.outputBoundary(start: outputFrame, sourceFrames: file.frameCount - sourceFrame,
                                             sourceRate: file.sampleRate, outputRate: outputRate)
            let token = ScheduleToken(generation: generation)
            let scheduleID = UUID()
            let replayGain = media.descriptor.replayGain ?? .empty
            graph.setReplayGain(
                replayGainScalar(mode: replayGainMode, values: replayGain, preampDB: replayGainPreampDB),
                slot: slot
            )
            stage = .scheduling
            try graph.schedule(slot: slot, sourceFrame: sourceFrame, outputFrame: outputFrame) { [weak self] in
                guard let self else { return }
                // Never resolve files, mutate nodes, or publish events on an audio callback.
                self.serialization.async { [weak self] in
                    guard let self, self.current?.id == scheduleID || self.following?.id == scheduleID else { return }
                    self.complete(index: index, slot: slot, token: token)
                }
            }
            return Prepared(
                id: scheduleID,
                index: index,
                slot: slot,
                url: url,
                file: file,
                sourceFrame: sourceFrame,
                endOutputFrame: end,
                sourceFormat: SourceFormatDescriptor(
                    codec: media.descriptor.codec, container: media.descriptor.container,
                    sampleRate: file.sampleRate, channelCount: media.descriptor.channelCount,
                    bitDepth: media.descriptor.bitDepth,
                    duration: Double(file.frameCount) / file.sampleRate,
                    replayGain: media.descriptor.replayGain)
            )
        } catch {
            graph.closeScheduledFile(slot: slot)
            resolver.release(url)
            throw QueueSchedulerError.preparation(stage, trackID: item.trackID, error: error)
        }
    }

    private func discardFollowing() {
        guard let obsolete = following else { return }
        following = nil // Reject stop-triggered callbacks before closing the alternate node.
        earlyCompletions.remove(obsolete.index)
        graph.closeScheduledFile(slot: obsolete.slot)
        resolver.release(obsolete.url)
    }

    private func prepareFollowing() throws {
        guard let current, let next = Self.successor(after: current.index, count: items.count, mode: repeatMode) else { return }
        following = try prepareItem(index: next, slot: current.slot == .a ? .b : .a,
                                    position: 0, outputFrame: current.endOutputFrame)
    }

    static func successor(after index: Int, count: Int, mode: RepeatMode) -> Int? {
        guard index >= 0, index < count else { return nil }
        if mode == .one { return index }
        if index + 1 < count { return index + 1 }
        return mode == .all ? 0 : nil
    }

    private func applyReplayGain(to prepared: Prepared?) {
        guard let prepared else { return }
        graph.setReplayGain(
            replayGainScalar(
                mode: replayGainMode,
                values: prepared.sourceFormat.replayGain ?? .empty,
                preampDB: replayGainPreampDB
            ),
            slot: prepared.slot
        )
    }

    private func start() throws {
        guard let current else { throw QueueSchedulerError.emptyQueue }
        try graph.startScheduledPlayback()
        playing = true
        emit(.started(trackID: items[current.index].trackID, index: current.index, token: ScheduleToken(generation: generation)))
    }

    private func complete(index: Int, slot: AudioSlot, token: ScheduleToken, prepareNext: Bool = true) {
        guard token.generation == generation, playing else { return }
        // AVAudioPlayerNode callback queues need not deliver two node completions
        // in audible order, especially with tiny files or a busy control queue.
        if let following, following.index == index, following.slot == slot {
            earlyCompletions.insert(index)
            return
        }
        guard let finished = current, finished.index == index, finished.slot == slot else { return }
        let finishedID = items[index].trackID
        graph.closeScheduledFile(slot: slot)
        resolver.release(finished.url)
        current = nil
        if let following {
            current = following
            self.following = nil
            self.index = following.index
            self.slot = following.slot
            position = 0
            retainedSourceFrame = nil
            do {
                // The alternate player already started at the scheduled boundary.
                if prepareNext { try prepareFollowing() }
                emit(.handoff(fromTrackID: finishedID, toTrackID: items[following.index].trackID,
                              index: following.index, token: token))
                if earlyCompletions.remove(following.index) != nil {
                    complete(index: following.index, slot: following.slot, token: token, prepareNext: prepareNext)
                }
            } catch { fail(error) }
        } else if !prepareNext && items.indices.contains(index + 1) {
            // Both prepared players can be exhausted when control work was delayed.
            // The unscheduled successor has not played: retain its frame zero for
            // resume, without opening obsolete media during pause/replacement.
            self.index = index + 1
            position = 0
            retainedSourceFrame = nil
            playing = false
            graph.cancelScheduledPlayback()
        } else {
            position = Double(finished.file.frameCount) / finished.file.sampleRate
            playing = false
            reachedEnd = true
            retainedSourceFrame = nil
            graph.cancelScheduledPlayback()
            emit(.completed(trackID: finishedID, token: token))
        }
    }

    private func capturePosition() {
        while let current {
            let elapsed = playing ? max(0, graph.elapsedSourceFrames(slot: current.slot) ?? 0) : 0
            let remaining = current.file.frameCount - current.sourceFrame
            if playing && elapsed >= remaining {
                // Reconcile the native timeline before retaining a resumable frame.
                // Do not prepare another file: the caller is about to invalidate.
                complete(index: current.index, slot: current.slot,
                         token: ScheduleToken(generation: generation), prepareNext: false)
                continue
            }
            let frame = current.sourceFrame + elapsed
            position = Double(frame) / current.file.sampleRate
            retainedSourceFrame = frame
            return
        }
    }

    private func invalidate() {
        generation &+= 1 // Advance before stopping players: stop may invoke their callbacks.
        playing = false
        earlyCompletions.removeAll()
        graph.cancelScheduledPlayback()
        if let current { graph.closeScheduledFile(slot: current.slot); resolver.release(current.url) }
        if let following { graph.closeScheduledFile(slot: following.slot); resolver.release(following.url) }
        current = nil
        following = nil
    }

    private func performing(_ body: () throws -> Void) throws {
        do { try body() }
        catch { throw fail(error) }
    }

    @discardableResult
    private func fail(_ error: Error) -> QueueSchedulerError {
        let trackID = index.map { items[$0].trackID }
        let failure = QueueSchedulerError.preparation(.playbackOperation, trackID: trackID, error: error)
        invalidate()
        let failedID: String?
        switch failure {
        case .media(let id, _): failedID = id
        case .operation(let id, _): failedID = id
        default: failedID = trackID
        }
        emit(.failed(trackID: failedID, error: failure, token: ScheduleToken(generation: generation)))
        return failure
    }

    private func emit(_ event: SchedulerEvent) {
        guard let handler = eventHandler else { return }
        DispatchQueue.main.async { handler(event) }
    }
}
