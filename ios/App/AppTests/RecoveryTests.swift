import XCTest
@testable import App

final class RecoveryTests: XCTestCase {
    func testRecoveryEscalatesNodeThenEngineThenSession() throws {
        var attempts: [RecoveryLevel] = []
        let recovery = RecoveryCoordinator(
            node: { _ in attempts.append(.node); throw TestFailure.failed },
            engine: { _ in attempts.append(.engine); throw TestFailure.failed },
            session: { _ in attempts.append(.session) }
        )

        let result = try recovery.recover(
            from: .node,
            checkpoint: PlaybackRecoveryCheckpoint(position: 12, userIntent: .playing)
        )

        XCTAssertEqual(attempts, [.node, .engine, .session])
        XCTAssertEqual(result, RecoveryResult(level: .session, resumed: true))
    }

    func testRecoveryStopsAfterThirdFailure() {
        var attemptCount = 0
        let fail: RecoveryCoordinator.Attempt = { _ in attemptCount += 1; throw TestFailure.failed }
        let recovery = RecoveryCoordinator(node: fail, engine: fail, session: fail)

        XCTAssertThrowsError(try recovery.recover(
            checkpoint: PlaybackRecoveryCheckpoint(position: 0, userIntent: .playing)
        )) { error in
            XCTAssertEqual(error as? RecoveryError, .exhausted(attempts: 3))
        }
        XCTAssertEqual(attemptCount, 3)
    }

    func testPausedIntentNeverReportsResume() throws {
        let recovery = RecoveryCoordinator(node: { _ in }, engine: { _ in }, session: { _ in })

        let result = try recovery.recover(
            checkpoint: PlaybackRecoveryCheckpoint(position: 4, userIntent: .paused)
        )

        XCTAssertEqual(result, RecoveryResult(level: .node, resumed: false))
    }

    func testMinimumLevelSkipsLowerRecovery() throws {
        var attempts: [RecoveryLevel] = []
        let recovery = RecoveryCoordinator(
            node: { _ in attempts.append(.node) },
            engine: { _ in attempts.append(.engine) },
            session: { _ in attempts.append(.session) }
        )

        let result = try recovery.recover(
            from: .engine,
            checkpoint: PlaybackRecoveryCheckpoint(position: 0, userIntent: .paused)
        )

        XCTAssertEqual(attempts, [.engine])
        XCTAssertEqual(result.level, .engine)
    }

    private enum TestFailure: Error { case failed }
}
