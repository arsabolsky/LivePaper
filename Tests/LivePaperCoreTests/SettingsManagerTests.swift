import XCTest
@testable import LivePaperCore

final class SettingsManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: SettingsManager!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LivePaperTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        settings = SettingsManager(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        settings = nil
        suiteName = nil
        super.tearDown()
    }

    func testWallpaperHistoryDeduplicatesAndCapsAtTen() {
        for index in 0..<12 {
            settings.addToHistory("/tmp/\(index).jpg")
        }
        settings.addToHistory("/tmp/5.jpg")

        XCTAssertEqual(settings.wallpaperHistory.count, 10)
        XCTAssertEqual(settings.wallpaperHistory.first, "/tmp/5.jpg")
    }

    func testOnboardingCompletedPersists() {
        settings.onboardingCompleted = true
        XCTAssertTrue(settings.onboardingCompleted)
    }

    func testScreenConfigRoundTrip() {
        let screenID = "screen_42"
        var config = Screen_Config.default
        config.folderPath = "/tmp/wallpapers"
        config.rotationIntervalMinutes = 30
        config.isShuffleMode = true

        settings.setScreenConfig(config, for: screenID)
        let retrieved = settings.screenConfig(for: screenID)

        XCTAssertEqual(retrieved.folderPath, "/tmp/wallpapers")
        XCTAssertEqual(retrieved.rotationIntervalMinutes, 30)
        XCTAssertTrue(retrieved.isShuffleMode)
    }

    func testScreenConfigDefaultForUnknownScreen() {
        let config = settings.screenConfig(for: "nonexistent_screen")
        XCTAssertEqual(config, Screen_Config.default)
    }

    func testPausePolicyDefaultsAreOff() {
        XCTAssertEqual(settings.batteryPausePolicy, .off)
        XCTAssertEqual(settings.visibilityPausePolicy, .off)
    }

    func testPausePolicyRoundTrip() {
        settings.batteryPausePolicy = .followLowPowerMode
        settings.visibilityPausePolicy = .unfocused
        XCTAssertEqual(settings.batteryPausePolicy, .followLowPowerMode)
        XCTAssertEqual(settings.visibilityPausePolicy, .unfocused)
    }

    func testMigrationTranslatesOldBatterySaverToLowBattery() {
        defaults.set(true, forKey: "livepaper_pause_when_invisible")
        settings.migratePausePoliciesIfNeeded()
        XCTAssertEqual(settings.batteryPausePolicy, .lowBattery)
        XCTAssertNil(defaults.object(forKey: "livepaper_pause_when_invisible"))
    }

    func testMigrationTranslatesOldOcclusionToCovered() {
        defaults.set(true, forKey: "livepaper_pause_when_occluded")
        settings.migratePausePoliciesIfNeeded()
        XCTAssertEqual(settings.visibilityPausePolicy, .covered)
        XCTAssertNil(defaults.object(forKey: "livepaper_pause_when_occluded"))
    }

    func testMigrationFalseOldKeysBecomeOff() {
        defaults.set(false, forKey: "livepaper_pause_when_invisible")
        defaults.set(false, forKey: "livepaper_pause_when_occluded")
        settings.migratePausePoliciesIfNeeded()
        XCTAssertEqual(settings.batteryPausePolicy, .off)
        XCTAssertEqual(settings.visibilityPausePolicy, .off)
    }

    func testMigrationDeletesThermalKey() {
        defaults.set(true, forKey: "livepaper_pause_under_thermal")
        settings.migratePausePoliciesIfNeeded()
        XCTAssertNil(defaults.object(forKey: "livepaper_pause_under_thermal"))
    }

    func testMigrationDoesNotClobberExistingNewPolicy() {
        settings.batteryPausePolicy = .onBattery
        defaults.set(true, forKey: "livepaper_pause_when_invisible") // stale old key
        settings.migratePausePoliciesIfNeeded()
        XCTAssertEqual(settings.batteryPausePolicy, .onBattery) // new key wins, not overwritten
    }
}
