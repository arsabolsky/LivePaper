// SakuraPrefs.swift — extension-side reader for sakura-prefs.json.
// Adapted from PhospheneExtension/WallpaperPrefs.swift.
// Changes: class renamed SakuraPrefsProvider to avoid clash with the SakuraPrefs struct
//          in SakuraPrefsModel.swift; uses com.sakura.wallpaper notification names;
//          per-display and sync-group config included alongside global pause flags.
//
// The app writes sakura-prefs.json (via SakuraPrefsWriter) then posts prefsChanged.
// The extension reloads the file and recomputes the playback policy for all renderers.

import Foundation
import os

final class SakuraPrefsProvider: Sendable {
    static let shared = SakuraPrefsProvider()

    private let lock = OSAllocatedUnfairLock(initialState: SakuraPrefs())

    private init() {
        reload()
    }

    // MARK: - Prefs accessors (playback-relevant subset)

    var userPaused: Bool         { lock.withLock { $0.userPaused } }
    var alwaysPauseDesktop: Bool { lock.withLock { $0.alwaysPauseDesktop } }
    var pauseWhenOccluded: Bool  { lock.withLock { $0.pauseWhenOccluded } }
    var desktopOccluded: Bool    { lock.withLock { $0.desktopOccluded } }
    var pausedDisplays: Set<UInt32> { lock.withLock { $0.pausedDisplays ?? [] } }

    /// Full prefs snapshot — used by RotationEngine (Phase 4) to read per-display rotation config.
    var current: SakuraPrefs { lock.withLock { $0 } }

    // MARK: - File reload

    /// Re-read sakura-prefs.json from the container Documents directory.
    /// Called on startup and on every prefsChanged Darwin notification.
    func reload() {
        guard let data = try? Data(contentsOf: Self.prefsURL) else {
            // File doesn't exist yet — normal on first launch before the app has run.
            return
        }
        do {
            let prefs = try JSONDecoder().decode(SakuraPrefs.self, from: data)
            lock.withLock { $0 = prefs }
            extensionLog("[SakuraPrefs] Loaded: userPaused=\(prefs.userPaused), alwaysPauseDesktop=\(prefs.alwaysPauseDesktop), displays=\(prefs.perDisplayConfig.count), syncGroups=\(prefs.syncGroups.count)")
        } catch {
            extensionLog("[SakuraPrefs] Decode failed: \(error)")
        }
    }

    // MARK: - Darwin notification observer

    // Written once from SakuraWallpaperExtension.init on the main thread before any concurrent
    // access is possible — nonisolated(unsafe) is safe here.
    nonisolated(unsafe) private var isObservingChanges = false

    /// Register for com.sakura.wallpaper.prefsChanged. Call once at extension startup (after dlopen).
    func observeChanges() {
        guard !isObservingChanges else { return }
        isObservingChanges = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let provider = Unmanaged<SakuraPrefsProvider>.fromOpaque(observer).takeUnretainedValue()
                // Reload first — policy computation reads the new prefs values.
                provider.reload()
                // Recompute on the Darwin notification queue; forEachRenderer is
                // queue-safe because it releases the lock before calling renderers.
                SakuraWallpaperExtension.recomputeAndApplyPolicy()
            },
            SakuraNotification.prefsChanged as CFString,
            nil,
            .deliverImmediately
        )
        extensionLog("[SakuraPrefs] Observing com.sakura.wallpaper.prefsChanged")
    }

    // MARK: - Private

    // From within the sandboxed extension, homeDirectory resolves to the container.
    // sakura-prefs.json lives in Documents/ alongside the video library.
    private static var prefsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/sakura-prefs.json")
    }
}
