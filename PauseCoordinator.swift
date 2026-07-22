import Foundation

/// What a screen's window/player should be doing right now.
enum ScreenPlaybackState: Equatable {
    case playing // window ordered in, video playing (sync-aligned on entry)
    case frozen  // window ordered in, video paused on last frame
    case hidden  // window ordered out, video paused (static desktop shows)
}

/// Applies a desired playback state to one screen. Implemented by
/// WallpaperManager over its ScreenPlayers.
protocol ScreenPlaybackControl: AnyObject {
    func apply(_ state: ScreenPlaybackState, to screenID: String)
}

/// Diffs desired playback states against what has been applied and drives only
/// the transitions. Holds no policy — it is fed reason sets and translates them.
final class PauseCoordinator {
    private(set) var applied: [String: ScreenPlaybackState] = [:]

    static func desiredState(for reasons: Set<PauseReason>) -> ScreenPlaybackState {
        if reasons.isEmpty { return .playing }
        if reasons.contains(where: { $0.hidesWindow }) { return .hidden }
        return .frozen
    }

    /// Applies desired states for every screen in `reasonsByScreen`, calling
    /// `control` only where the state changed. Forgets screens no longer present.
    /// Returns true if anything changed.
    @discardableResult
    func reconcile(reasonsByScreen: [String: Set<PauseReason>], control: ScreenPlaybackControl) -> Bool {
        var changed = false
        for (id, reasons) in reasonsByScreen {
            let desired = PauseCoordinator.desiredState(for: reasons)
            if applied[id] != desired {
                applied[id] = desired
                control.apply(desired, to: id)
                changed = true
            }
        }
        let present = Set(reasonsByScreen.keys)
        for id in Array(applied.keys) where !present.contains(id) {
            applied.removeValue(forKey: id)
        }
        return changed
    }

    func reset() { applied.removeAll() }
}
