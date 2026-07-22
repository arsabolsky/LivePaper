import XCTest
@testable import LivePaperCore

final class PausePolicyTests: XCTestCase {
    func testHidesWindowOnlyForManualReasons() {
        XCTAssertTrue(PauseReason.manualAll.hidesWindow)
        XCTAssertTrue(PauseReason.manualScreen.hidesWindow)
        XCTAssertFalse(PauseReason.lowBattery.hidesWindow)
        XCTAssertFalse(PauseReason.asleep.hidesWindow)
        XCTAssertFalse(PauseReason.covered.hidesWindow)
        XCTAssertFalse(PauseReason.desktopUnfocused.hidesWindow)
    }

    func testStatusPriorityOrder() {
        XCTAssertGreaterThan(PauseReason.manualAll.statusPriority, PauseReason.manualScreen.statusPriority)
        XCTAssertGreaterThan(PauseReason.manualScreen.statusPriority, PauseReason.lowBattery.statusPriority)
        XCTAssertGreaterThan(PauseReason.lowBattery.statusPriority, PauseReason.asleep.statusPriority)
        XCTAssertGreaterThan(PauseReason.asleep.statusPriority, PauseReason.covered.statusPriority)
        XCTAssertEqual(PauseReason.covered.statusPriority, PauseReason.desktopUnfocused.statusPriority)
    }

    func testPolicyRawValuesAreStable() {
        XCTAssertEqual(BatteryPausePolicy(rawValue: "followLowPowerMode"), .followLowPowerMode)
        XCTAssertEqual(VisibilityPausePolicy(rawValue: "unfocused"), .unfocused)
    }
}
