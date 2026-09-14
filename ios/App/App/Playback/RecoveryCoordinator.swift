import Foundation

enum RecoveryLevel: Int, Codable, CaseIterable {
    case node = 1
    case engine = 2
    case session = 3
}

struct RecoveryResult: Codable, Equatable {
    let level: RecoveryLevel
    let resumed: Bool
}

struct PlaybackRecoveryCheckpoint: Equatable {
    let position: Double
    let userIntent: PlaybackIntent
}

protocol PlaybackRecovering: AnyObject {
    func recover(from level: RecoveryLevel, checkpoint: PlaybackRecoveryCheckpoint) throws -> RecoveryResult
}

enum RecoveryError: Error, Equatable {
    case exhausted(attempts: Int)
}

final class RecoveryCoordinator: PlaybackRecovering {
    typealias Attempt = (PlaybackRecoveryCheckpoint) throws -> Void

    private let nodeAttempt: Attempt
    private let engineAttempt: Attempt
    private let sessionAttempt: Attempt

    init(node: @escaping Attempt, engine: @escaping Attempt, session: @escaping Attempt) {
        nodeAttempt = node
        engineAttempt = engine
        sessionAttempt = session
    }

    convenience init(
        scheduler: PlaybackScheduling,
        graph: PlaybackGraphControlling,
        session: AudioSessionActivating
    ) {
        func restore(_ checkpoint: PlaybackRecoveryCheckpoint) throws {
            try scheduler.prepareCurrent(position: checkpoint.position)
            if checkpoint.userIntent == .playing { try scheduler.play() }
        }
        self.init(
            node: { checkpoint in
                scheduler.invalidatePendingSchedule()
                try restore(checkpoint)
            },
            engine: { checkpoint in
                scheduler.invalidatePendingSchedule()
                try graph.rebuild()
                try restore(checkpoint)
            },
            session: { checkpoint in
                scheduler.invalidatePendingSchedule()
                try session.activate()
                try graph.rebuild()
                try restore(checkpoint)
            }
        )
    }

    func recover(from level: RecoveryLevel = .node, checkpoint: PlaybackRecoveryCheckpoint) throws -> RecoveryResult {
        let attempts: [(RecoveryLevel, Attempt)] = [
            (.node, nodeAttempt),
            (.engine, engineAttempt),
            (.session, sessionAttempt)
        ]
        var count = 0
        for (candidate, attempt) in attempts where candidate.rawValue >= level.rawValue {
            count += 1
            do {
                try attempt(checkpoint)
                return RecoveryResult(level: candidate, resumed: checkpoint.userIntent == .playing)
            } catch {
                continue
            }
        }
        throw RecoveryError.exhausted(attempts: count)
    }
}
