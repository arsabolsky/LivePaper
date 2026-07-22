import Foundation

/// A snapshot of every input that determines pause state, sampled at one
/// instant so derivation is a pure function of this value.
struct PauseInputs {
    var screenIDs: [String]
    var manualAll: Bool
    var manualScreens: Set<String>
    var systemAsleep: Bool
    var power: PowerState
    var batteryPolicy: BatteryPausePolicy
    var visibilityPolicy: VisibilityPausePolicy
    var occludedScreens: Set<String>
    var desktopFrontmost: Bool
}

/// Aggregate playback state across all screens, for the menu-bar status line.
enum PlaybackSummary: Equatable {
    case stopped
    case playing
    case paused(PauseReason) // all screens paused; dominant reason
    case partiallyPaused     // some paused, some playing
}

enum PauseEvaluator {
    static let lowBatteryThreshold = 20

    static func batteryConditionMet(_ policy: BatteryPausePolicy, _ power: PowerState) -> Bool {
        switch policy {
        case .off:
            return false
        case .lowBattery:
            guard let level = power.batteryLevel else { return false }
            return !power.isCharging && level <= lowBatteryThreshold
        case .onBattery:
            return !power.isCharging && power.batteryLevel != nil
        case .followLowPowerMode:
            return power.lowPowerModeEnabled
        }
    }

    static func reasons(for id: String, _ i: PauseInputs) -> Set<PauseReason> {
        var r: Set<PauseReason> = []
        if i.manualAll { r.insert(.manualAll) }
        if i.manualScreens.contains(id) { r.insert(.manualScreen) }
        if i.systemAsleep { r.insert(.asleep) }
        if batteryConditionMet(i.batteryPolicy, i.power) { r.insert(.lowBattery) }
        switch i.visibilityPolicy {
        case .off:
            break
        case .covered:
            if i.occludedScreens.contains(id) { r.insert(.covered) }
        case .unfocused:
            if !i.desktopFrontmost { r.insert(.desktopUnfocused) }
        }
        return r
    }

    static func reasonsByScreen(_ i: PauseInputs) -> [String: Set<PauseReason>] {
        var out: [String: Set<PauseReason>] = [:]
        for id in i.screenIDs { out[id] = reasons(for: id, i) }
        return out
    }

    static func summarize(_ reasonsByScreen: [String: Set<PauseReason>], isActive: Bool) -> PlaybackSummary {
        guard isActive, !reasonsByScreen.isEmpty else { return .stopped }
        let pausedScreens = reasonsByScreen.filter { !$0.value.isEmpty }
        if pausedScreens.isEmpty { return .playing }
        if pausedScreens.count < reasonsByScreen.count { return .partiallyPaused }
        let dominant = pausedScreens.values
            .flatMap { $0 }
            .max { $0.statusPriority < $1.statusPriority }
        return dominant.map { .paused($0) } ?? .partiallyPaused
    }
}
