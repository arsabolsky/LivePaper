import Foundation

/// How aggressively to pause when running on battery.
enum BatteryPausePolicy: String, CaseIterable {
    case off
    case lowBattery         // <= 20% and not on AC
    case onBattery          // any level, whenever not on AC
    case followLowPowerMode // whenever macOS Low Power Mode is on
}

/// When to pause based on whether the wallpaper is actually being seen.
enum VisibilityPausePolicy: String, CaseIterable {
    case off
    case covered   // this screen's window fully occluded (per-screen)
    case unfocused // another app is frontmost (global)
}

/// A single, closed set of reasons a screen's playback may be paused.
enum PauseReason: String, Hashable, CaseIterable {
    case manualAll
    case manualScreen
    case lowBattery
    case asleep
    case covered
    case desktopUnfocused

    /// Reasons whose pause should also hide the wallpaper window (revealing the
    /// static desktop copy). All other reasons merely freeze the current frame.
    var hidesWindow: Bool {
        switch self {
        case .manualAll, .manualScreen: return true
        case .lowBattery, .asleep, .covered, .desktopUnfocused: return false
        }
    }

    /// Higher wins when choosing the dominant reason for the status label.
    var statusPriority: Int {
        switch self {
        case .manualAll:        return 5
        case .manualScreen:     return 4
        case .lowBattery:       return 3
        case .asleep:           return 2
        case .covered:          return 1
        case .desktopUnfocused: return 1
        }
    }
}

/// Raw power inputs, sampled live. `isCharging` means "on external/AC power".
/// `batteryLevel` is nil when there is no battery (desktop Macs).
struct PowerState: Equatable {
    var batteryLevel: Int?
    var isCharging: Bool
    var lowPowerModeEnabled: Bool
}
