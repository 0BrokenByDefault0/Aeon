import UniformTypeIdentifiers
import XCTest
@testable import App

/// Choosing a file dismisses the picker, so the dismissal callback arrives
/// before the one carrying the URLs. Treating the dismissal as a cancel threw
/// the selection away and made Open look like it did nothing on device.
@MainActor
final class ImportPickerCoordinatorTests: XCTestCase {
    func testAPickThatArrivesAfterTheDismissalIsStillAPick() {
        let coordinator = ImportPickerPresenter.Coordinator()
        var outcomes: [ImportPickerOutcome] = []
        coordinator.completion = { outcome, _ in outcomes.append(outcome) }
        coordinator.beginTracking(.audioFiles)

        coordinator.scheduleCancelAfterDismissal(after: 0.05)
        coordinator.documentPicker(
            UIDocumentPickerViewController(forOpeningContentTypes: [.audio]),
            didPickDocumentsAt: [URL(fileURLWithPath: "/tmp/track.wav")]
        )

        let settled = expectation(description: "the deferred cancel has had its chance")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 1)

        XCTAssertEqual(outcomes.count, 1, "the deferred cancel must not add a second outcome")
        guard case .picked(let urls) = outcomes.first else {
            return XCTFail("expected the pick to win, got \(String(describing: outcomes.first))")
        }
        XCTAssertEqual(urls.count, 1)
    }

    func testADismissalWithNoPickIsACancel() {
        let coordinator = ImportPickerPresenter.Coordinator()
        var outcomes: [ImportPickerOutcome] = []
        coordinator.completion = { outcome, _ in outcomes.append(outcome) }
        coordinator.beginTracking(.folder)

        coordinator.scheduleCancelAfterDismissal(after: 0.05)

        let settled = expectation(description: "cancel lands")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 1)

        guard case .cancelled = outcomes.first else {
            return XCTFail("swiping the picker away should still cancel")
        }
        XCTAssertEqual(outcomes.count, 1)
    }

    func testAnExplicitCancelIsNotDelayed() {
        let coordinator = ImportPickerPresenter.Coordinator()
        var outcomes: [ImportPickerOutcome] = []
        coordinator.completion = { outcome, _ in outcomes.append(outcome) }
        coordinator.beginTracking(.audioFiles)

        coordinator.documentPickerWasCancelled(
            UIDocumentPickerViewController(forOpeningContentTypes: [.audio])
        )

        guard case .cancelled = outcomes.first else {
            return XCTFail("tapping Cancel should report immediately")
        }
    }
}
