import Foundation
import ServiceManagement
import Cocoa

class SettingsManager {
    static let shared = SettingsManager()

    private let defaults: UserDefaults

    // MARK: - UserDefaults Keys (retained)
    private let launchKey                = "livepaper_launch_at_login"
    private let pauseWhenInvisibleKey    = "livepaper_pause_when_invisible"
    private let pauseWhenOccludedKey     = "livepaper_pause_when_occluded"
    private let pauseUnderThermalKey     = "livepaper_pause_under_thermal"
    private let historyKey               = "livepaper_history"
    private let languageKey              = "livepaper_language"
    private let onboardingCompletedKey   = "livepaper_onboarding_completed"
    private let syncDesktopWallpaperKey  = "livepaper_sync_desktop_wallpaper"

    // MARK: - UserDefaults Keys (new)
    private let screenRegistryKey        = "livepaper_screen_registry"
    private let newScreenPolicyKey       = "livepaper_new_screen_policy"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Screen Registry API

    func screenConfig(for screenID: String) -> Screen_Config {
        guard let data = defaults.data(forKey: screenRegistryKey) else {
            return Screen_Config.default
        }
        do {
            let registry = try JSONDecoder().decode(Screen_Registry.self, from: data)
            return registry[screenID] ?? Screen_Config.default
        } catch {
            print("SettingsManager: failed to decode screen registry: \(error)")
            return Screen_Config.default
        }
    }

    func setScreenConfig(_ config: Screen_Config, for screenID: String) {
        var registry: Screen_Registry
        if let data = defaults.data(forKey: screenRegistryKey),
           let decoded = try? JSONDecoder().decode(Screen_Registry.self, from: data) {
            registry = decoded
        } else {
            registry = [:]
        }
        registry[screenID] = config
        if let data = try? JSONEncoder().encode(registry) {
            defaults.set(data, forKey: screenRegistryKey)
        }
    }

    // MARK: - New Screen Policy

    var newScreenPolicy: New_Screen_Policy {
        get {
            guard let raw = defaults.string(forKey: newScreenPolicyKey),
                  let policy = New_Screen_Policy(rawValue: raw) else {
                return .inheritSyncGroup
            }
            return policy
        }
        set {
            defaults.set(newValue.rawValue, forKey: newScreenPolicyKey)
        }
    }

    // MARK: - Clean-Slate Init

    func runCleanSlateInitIfNeeded() {
        // Guard: if registry already exists, do nothing
        guard defaults.object(forKey: screenRegistryKey) == nil else { return }

        // Delete all legacy keys
        let legacyKeys = [
            "livepaper_folder_path",
            "livepaper_wallpaper_path",
            "livepaper_screen_folder_configs",
            "livepaper_screen_wallpapers",
            "livepaper_is_folder_mode",
            "livepaper_rotation_interval_minutes",
            "livepaper_is_shuffle_mode",
            "livepaper_is_rotation_enabled",
            "livepaper_include_subfolders",
            "livepaper_new_screen_inheritance_mode",
            "livepaper_new_screen_inheritance_screen_id"
        ]
        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }

        // Initialize empty registry
        let emptyRegistry: Screen_Registry = [:]
        if let data = try? JSONEncoder().encode(emptyRegistry) {
            defaults.set(data, forKey: screenRegistryKey)
        }
    }

    // MARK: - Retained Properties

    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: onboardingCompletedKey) }
        set { defaults.set(newValue, forKey: onboardingCompletedKey) }
    }

    var launchAtLogin: Bool {
        get { defaults.bool(forKey: launchKey) }
        set {
            defaults.set(newValue, forKey: launchKey)
            updateLoginItem(enabled: newValue)
        }
    }

    var pauseWhenInvisible: Bool {
        get { defaults.bool(forKey: pauseWhenInvisibleKey) }
        set { defaults.set(newValue, forKey: pauseWhenInvisibleKey) }
    }

    /// When enabled, a screen's wallpaper playback pauses while its window is
    /// fully covered by other windows (i.e. the desktop is not visible), and
    /// resumes as soon as the desktop becomes visible again. Evaluated per screen.
    var pauseWhenOccluded: Bool {
        get { defaults.bool(forKey: pauseWhenOccludedKey) }
        set { defaults.set(newValue, forKey: pauseWhenOccludedKey) }
    }

    /// When enabled, all playback pauses while the machine is under serious or
    /// critical thermal pressure and resumes once it cools down. Opt-in and
    /// independent of Battery Saver (`pauseWhenInvisible`).
    var pauseUnderThermalPressure: Bool {
        get { defaults.bool(forKey: pauseUnderThermalKey) }
        set { defaults.set(newValue, forKey: pauseUnderThermalKey) }
    }

    var syncDesktopWallpaper: Bool {
        get {
            if defaults.object(forKey: syncDesktopWallpaperKey) == nil { return true }
            return defaults.bool(forKey: syncDesktopWallpaperKey)
        }
        set { defaults.set(newValue, forKey: syncDesktopWallpaperKey) }
    }

    var wallpaperHistory: [String] {
        get { defaults.stringArray(forKey: historyKey) ?? [] }
        set { defaults.set(newValue, forKey: historyKey) }
    }

    var language: String {
        get { defaults.string(forKey: languageKey) ?? "system" }
        set { defaults.set(newValue, forKey: languageKey) }
    }

    // MARK: - Screen Identifier

    static func screenIdentifier(_ screen: NSScreen) -> String {
        return screenIdentifier(deviceDescription: screen.deviceDescription, name: screen.localizedName)
    }

    /// Testable core of screenIdentifier. Accepts raw device description and name
    /// so tests can exercise the logic without instantiating NSScreen.
    static func screenIdentifier(deviceDescription: [NSDeviceDescriptionKey: Any], name: String) -> String {
        if let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "screen_\(number.uint32Value)"
        }
        // Deterministic fallback derived from stable screen properties (Bug 3 fix).
        // Uses localizedName + frame dimensions so the same physical screen always
        // maps to the same identifier, even when NSScreenNumber is temporarily unavailable.
        let sizeValue = deviceDescription[NSDeviceDescriptionKey("NSDeviceSize")] as? NSValue
        let size = sizeValue?.sizeValue ?? .zero
        let w = Int(size.width)
        let h = Int(size.height)
        return "screen_fallback_\(name)_\(w)x\(h)"
    }

    // MARK: - Private Helpers

    func addToHistory(_ path: String) {
        var history = wallpaperHistory.filter { $0 != path }
        history.insert(path, at: 0)
        if history.count > 10 { history = Array(history.prefix(10)) }
        wallpaperHistory = history
    }

    private func updateLoginItem(enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled { try service.register() } else { try service.unregister() }
            } catch {
                print("Failed to update login item: \(error)")
            }
        }
    }
}
