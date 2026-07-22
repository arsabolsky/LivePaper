import XCTest
@testable import LivePaperCore

private final class FakeControl: ScreenPlaybackControl {
    var calls: [(String, ScreenPlaybackState)] = []
    func apply(_ state: ScreenPlaybackState, to screenID: String) {
        calls.append((screenID, state))
    }
}

final class PauseCoordinatorTests: XCTestCase {
    func testDesiredState() {
        XCTAssertEqual(PauseCoordinator.desiredState(for: []), .playing)
        XCTAssertEqual(PauseCoordinator.desiredState(for: [.lowBattery]), .frozen)
        XCTAssertEqual(PauseCoordinator.desiredState(for: [.covered, .manualAll]), .hidden)
        XCTAssertEqual(PauseCoordinator.desiredState(for: [.manualScreen]), .hidden)
    }

    func testFirstReconcileAppliesAll() {
        let c = PauseCoordinator(); let ctrl = FakeControl()
        let changed = c.reconcile(reasonsByScreen: ["A": [], "B": [.lowBattery]], control: ctrl)
        XCTAssertTrue(changed)
        XCTAssertEqual(ctrl.calls.count, 2)
    }

    func testSecondReconcileIsIdempotent() {
        let c = PauseCoordinator(); let ctrl = FakeControl()
        _ = c.reconcile(reasonsByScreen: ["A": [], "B": [.lowBattery]], control: ctrl)
        ctrl.calls.removeAll()
        let changed = c.reconcile(reasonsByScreen: ["A": [], "B": [.lowBattery]], control: ctrl)
        XCTAssertFalse(changed)
        XCTAssertTrue(ctrl.calls.isEmpty) // no redundant re-apply / re-seek
    }

    func testOnlyChangedScreensReapply() {
        let c = PauseCoordinator(); let ctrl = FakeControl()
        _ = c.reconcile(reasonsByScreen: ["A": [], "B": []], control: ctrl)
        ctrl.calls.removeAll()
        _ = c.reconcile(reasonsByScreen: ["A": [.covered], "B": []], control: ctrl)
        XCTAssertEqual(ctrl.calls.count, 1)
        XCTAssertEqual(ctrl.calls.first?.0, "A")
        XCTAssertEqual(ctrl.calls.first?.1, .frozen)
    }

    func testRemovedScreenIsForgotten() {
        let c = PauseCoordinator(); let ctrl = FakeControl()
        _ = c.reconcile(reasonsByScreen: ["A": [], "B": []], control: ctrl)
        _ = c.reconcile(reasonsByScreen: ["A": []], control: ctrl) // B removed
        XCTAssertNil(c.applied["B"])
        // Re-adding B applies fresh
        ctrl.calls.removeAll()
        _ = c.reconcile(reasonsByScreen: ["A": [], "B": []], control: ctrl)
        XCTAssertEqual(ctrl.calls.map { $0.0 }, ["B"])
    }
}
