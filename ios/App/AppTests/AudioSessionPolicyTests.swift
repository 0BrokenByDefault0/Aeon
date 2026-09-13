import AVFoundation
import XCTest
@testable import App

final class AudioSessionPolicyTests: XCTestCase {
    func testRemovedPrivateOutputPausesBeforeSpeakerFallback() {
        let speaker = route(.speaker, "iPhone")
        for kind in [AudioRouteKind.wired, .usb, .bluetooth] {
            XCTAssertEqual(
                routeLossAction(old: route(kind, "Private output"), new: speaker, reason: .oldDeviceUnavailable),
                .pauseAndRebuild
            )
        }
    }

    func testNewDeviceAndSpeakerChangesDoNotForcePause() {
        XCTAssertEqual(
            routeLossAction(old: route(.speaker, "iPhone"), new: route(.wired, "Headphones"), reason: .newDeviceAvailable),
            .none
        )
        XCTAssertEqual(
            routeLossAction(old: route(.speaker, "iPhone"), new: nil, reason: .oldDeviceUnavailable),
            .none
        )
    }

    func testInterruptionResumesOnlyForSystemPermissionAndPlayingIntent() {
        XCTAssertTrue(interruptionShouldResume(systemAllowsResume: true, userIntent: .playing))
        XCTAssertFalse(interruptionShouldResume(systemAllowsResume: false, userIntent: .playing))
        XCTAssertFalse(interruptionShouldResume(systemAllowsResume: true, userIntent: .paused))
    }

    private func route(_ kind: AudioRouteKind, _ name: String) -> RouteDescriptor {
        RouteDescriptor(kind: kind, name: name, sampleRate: 48_000, channelCount: 2)
    }
}
