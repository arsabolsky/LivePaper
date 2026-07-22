import XCTest
@testable import LivePaperCore

final class PauseEvaluatorTests: XCTestCase {
    private func inputs(
        screens: [String] = ["A"],
        manualAll: Bool = false,
        manualScreens: Set<String> = [],
        asleep: Bool = false,
        level: Int? = 100,
        charging: Bool = true,
        lowPower: Bool = false,
        battery: BatteryPausePolicy = .off,
        visibility: VisibilityPausePolicy = .off,
        occluded: Set<String> = [],
        desktopFrontmost: Bool = true
    ) -> PauseInputs {
        PauseInputs(
            screenIDs: screens, manualAll: manualAll, manualScreens: manualScreens,
            systemAsleep: asleep,
            power: PowerState(batteryLevel: level, isCharging: charging, lowPowerModeEnabled: lowPower),
            batteryPolicy: battery, visibilityPolicy: visibility,
            occludedScreens: occluded, desktopFrontmost: desktopFrontmost)
    }

    func testNoReasonsWhenEverythingNominal() {
        XCTAssertTrue(PauseEvaluator.reasons(for: "A", inputs()).isEmpty)
    }

    func testManualAllAndScreen() {
        XCTAssertEqual(PauseEvaluator.reasons(for: "A", inputs(manualAll: true)), [.manualAll])
        XCTAssertEqual(PauseEvaluator.reasons(for: "A", inputs(manualScreens: ["A"])), [.manualScreen])
        XCTAssertTrue(PauseEvaluator.reasons(for: "B", inputs(screens: ["A","B"], manualScreens: ["A"])).isEmpty)
    }

    func testAsleep() {
        XCTAssertEqual(PauseEvaluator.reasons(for: "A", inputs(asleep: true)), [.asleep])
    }

    func testBatteryLowBatteryPolicy() {
        XCTAssertFalse(PauseEvaluator.batteryConditionMet(.lowBattery, PowerState(batteryLevel: 15, isCharging: true, lowPowerModeEnabled: false)))
        XCTAssertTrue(PauseEvaluator.batteryConditionMet(.lowBattery, PowerState(batteryLevel: 15, isCharging: false, lowPowerModeEnabled: false)))
        XCTAssertFalse(PauseEvaluator.batteryConditionMet(.lowBattery, PowerState(batteryLevel: 40, isCharging: false, lowPowerModeEnabled: false)))
    }

    func testBatteryOnBatteryPolicy() {
        XCTAssertTrue(PauseEvaluator.batteryConditionMet(.onBattery, PowerState(batteryLevel: 90, isCharging: false, lowPowerModeEnabled: false)))
        XCTAssertFalse(PauseEvaluator.batteryConditionMet(.onBattery, PowerState(batteryLevel: 90, isCharging: true, lowPowerModeEnabled: false)))
        // desktop Mac: no battery -> never
        XCTAssertFalse(PauseEvaluator.batteryConditionMet(.onBattery, PowerState(batteryLevel: nil, isCharging: false, lowPowerModeEnabled: false)))
    }

    func testBatteryFollowLowPowerMode() {
        XCTAssertTrue(PauseEvaluator.batteryConditionMet(.followLowPowerMode, PowerState(batteryLevel: 90, isCharging: true, lowPowerModeEnabled: true)))
        XCTAssertFalse(PauseEvaluator.batteryConditionMet(.followLowPowerMode, PowerState(batteryLevel: 5, isCharging: false, lowPowerModeEnabled: false)))
    }

    func testBatteryOffPolicyNeverPauses() {
        XCTAssertFalse(PauseEvaluator.batteryConditionMet(.off, PowerState(batteryLevel: 1, isCharging: false, lowPowerModeEnabled: true)))
    }

    func testVisibilityCoveredIsPerScreen() {
        let i = inputs(screens: ["A","B"], visibility: .covered, occluded: ["A"])
        XCTAssertEqual(PauseEvaluator.reasons(for: "A", i), [.covered])
        XCTAssertTrue(PauseEvaluator.reasons(for: "B", i).isEmpty)
    }

    func testVisibilityUnfocusedIsGlobal() {
        let i = inputs(screens: ["A","B"], visibility: .unfocused, desktopFrontmost: false)
        XCTAssertEqual(PauseEvaluator.reasons(for: "A", i), [.desktopUnfocused])
        XCTAssertEqual(PauseEvaluator.reasons(for: "B", i), [.desktopUnfocused])
    }

    func testVisibilityOffIgnoresOcclusion() {
        let i = inputs(visibility: .off, occluded: ["A"], desktopFrontmost: false)
        XCTAssertTrue(PauseEvaluator.reasons(for: "A", i).isEmpty)
    }

    func testOverlappingReasonsAllPresent() {
        let i = inputs(manualAll: true, asleep: true, level: 10, charging: false,
                       battery: .lowBattery, visibility: .covered, occluded: ["A"])
        XCTAssertEqual(PauseEvaluator.reasons(for: "A", i), [.manualAll, .asleep, .lowBattery, .covered])
    }

    func testSummarizeStoppedWhenInactive() {
        XCTAssertEqual(PauseEvaluator.summarize([:], isActive: false), .stopped)
    }

    func testSummarizePlayingWhenNoneePaused() {
        XCTAssertEqual(PauseEvaluator.summarize(["A": [], "B": []], isActive: true), .playing)
    }

    func testSummarizePartiallyPaused() {
        XCTAssertEqual(PauseEvaluator.summarize(["A": [.covered], "B": []], isActive: true), .partiallyPaused)
    }

    func testSummarizeAllPausedDominantReason() {
        XCTAssertEqual(PauseEvaluator.summarize(["A": [.lowBattery], "B": [.manualAll]], isActive: true), .paused(.manualAll))
    }
}
