import XCTest
import Cocoa
@testable import SakuraWallpaperCore

final class SettingsManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: SettingsManager!
    private var suiteName: String!
    private let screenRegistryKey = "sakurawallpaper_screen_registry"

    override func setUp() {
        super.setUp()
        suiteName = "SakuraWallpaperTests.\(UUID().uuidString)"
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
        config.wallpaperFit = .stretch
        config.isFolderBrowserVisible = true

        settings.setScreenConfig(config, for: screenID)
        let retrieved = settings.screenConfig(for: screenID)

        XCTAssertEqual(retrieved.folderPath, "/tmp/wallpapers")
        XCTAssertEqual(retrieved.rotationIntervalMinutes, 30)
        XCTAssertTrue(retrieved.isShuffleMode)
        XCTAssertEqual(retrieved.wallpaperFit, .stretch)
        XCTAssertTrue(retrieved.isFolderBrowserVisible)
    }

    func testScreenConfigDefaultForUnknownScreen() {
        let config = settings.screenConfig(for: "nonexistent_screen")
        XCTAssertEqual(config, Screen_Config.default)
        XCTAssertFalse(config.isFolderBrowserVisible)
    }

    func testScreenConfigDefaultsMissingFieldsWhenStoredJSONComesFromLegacyConfig() {
        let jsonString = """
        {
            "screen_legacy": {
                "folder_path": "/tmp/legacy",
                "wallpaper_path": null,
                "rotation_interval_minutes": 15,
                "is_shuffle_mode": false,
                "is_rotation_enabled": true,
                "include_subfolders": false,
                "is_folder_mode": false,
                "is_synced": true
            }
        }
        """
        defaults.set(Data(jsonString.utf8), forKey: screenRegistryKey)

        let config = settings.screenConfig(for: "screen_legacy")

        XCTAssertEqual(config.folderPath, "/tmp/legacy")
        XCTAssertEqual(config.wallpaperFit, .fill)
        XCTAssertFalse(config.isFolderBrowserVisible)
    }

    func testScreenConfigDefaultsWhenWallpaperFitRawValueIsInvalid() {
        let jsonString = """
        {
            "screen_invalid_fit": {
                "folder_path": null,
                "wallpaper_path": "/tmp/test.jpg",
                "rotation_interval_minutes": 15,
                "is_shuffle_mode": false,
                "is_rotation_enabled": true,
                "include_subfolders": false,
                "is_folder_mode": false,
                "is_synced": true,
                "wallpaper_fit": "bogus-value",
                "is_folder_browser_visible": true
            }
        }
        """
        defaults.set(Data(jsonString.utf8), forKey: screenRegistryKey)

        let config = settings.screenConfig(for: "screen_invalid_fit")

        XCTAssertEqual(config.wallpaperFit, .fill)
        XCTAssertTrue(config.isFolderBrowserVisible)
    }

    func testAppearanceModeDefaultsToSystem() {
        XCTAssertEqual(settings.appearanceMode, .system)
    }

    func testAppearanceModePersists() {
        settings.appearanceMode = .dark

        XCTAssertEqual(settings.appearanceMode, .dark)
    }

    func testAppearanceModeCanReturnToSystem() {
        settings.appearanceMode = .light
        settings.appearanceMode = .system

        XCTAssertEqual(settings.appearanceMode, .system)
    }

    func testOriginalDesktopRecordRoundTripPerScreen() {
        let record = OriginalDesktopRecord(
            imagePath: "/tmp/original.jpg",
            imageScalingRawValue: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            allowClipping: true,
            fillColorData: try! NSKeyedArchiver.archivedData(
                withRootObject: NSColor.systemBlue,
                requiringSecureCoding: true
            )
        )

        settings.setOriginalDesktopRecord(record, for: "screen_1")

        XCTAssertEqual(settings.originalDesktopRecord(for: "screen_1"), record)
        XCTAssertNil(settings.originalDesktopRecord(for: "screen_2"))
    }

    func testRemoveOriginalDesktopRecordOnlyDeletesTargetScreen() {
        settings.setOriginalDesktopRecord(
            OriginalDesktopRecord(
                imagePath: "/tmp/one.jpg",
                imageScalingRawValue: nil,
                allowClipping: true,
                fillColorData: nil
            ),
            for: "screen_1"
        )
        settings.setOriginalDesktopRecord(
            OriginalDesktopRecord(
                imagePath: "/tmp/two.jpg",
                imageScalingRawValue: nil,
                allowClipping: false,
                fillColorData: nil
            ),
            for: "screen_2"
        )

        settings.removeOriginalDesktopRecord(for: "screen_1")

        XCTAssertNil(settings.originalDesktopRecord(for: "screen_1"))
        XCTAssertEqual(
            settings.originalDesktopRecord(for: "screen_2"),
            OriginalDesktopRecord(
                imagePath: "/tmp/two.jpg",
                imageScalingRawValue: nil,
                allowClipping: false,
                fillColorData: nil
            )
        )
    }
}
