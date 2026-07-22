import Foundation

/// Pure playback-tuning decisions, isolated for testing.
enum PlaybackTuning {
    /// The frame rate to cap rendering at, or nil if no cap should be applied.
    ///
    /// Caps to `min(screenMaxFPS, 60)`, but only when the source exceeds that by
    /// more than 1 fps — so normal-rate clips (24/30/60) get no cap and therefore
    /// no video-composition overhead. `screenMaxFPS <= 0` (unknown refresh) falls
    /// back to 60.
    static func frameRateCapTarget(sourceFPS: Float, screenMaxFPS: Int) -> Int? {
        let refresh = screenMaxFPS > 0 ? screenMaxFPS : 60
        let target = min(refresh, 60)
        guard sourceFPS > Float(target) + 1 else { return nil }
        return target
    }
}
