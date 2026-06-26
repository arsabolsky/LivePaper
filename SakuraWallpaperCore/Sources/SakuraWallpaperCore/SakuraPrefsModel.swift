// SakuraPrefsModel.swift — shared Codable structs for the sakura-prefs.json IPC file.
// Shared between the app (SakuraPrefsWriter: writes) and the extension (SakuraPrefs: reads).
//
// Data flow:
//   App writes ~/Library/Containers/com.sakura.wallpaper.extension/Data/Documents/sakura-prefs.json
//   App posts Darwin notification com.sakura.wallpaper.prefsChanged
//   Extension reads the file on startup and on every prefsChanged notification
//
// Key mapping from old UserDefaults Screen_Registry → SakuraPrefs:
//   Screen_Config.folderPath              → SakuraDisplayConfig.folderPath
//   Screen_Config.rotationIntervalMinutes → SakuraDisplayConfig.rotationIntervalMinutes
//   Screen_Config.isShuffleMode           → SakuraDisplayConfig.isShuffleMode
//   Screen_Config.isRotationEnabled       → SakuraDisplayConfig.isRotationEnabled
//   Screen_Config.includeSubfolders       → SakuraDisplayConfig.includeSubfolders
//   Screen_Config.isFolderMode            → SakuraDisplayConfig.isFolderMode
//   Screen_Config.isSynced                → put into a SakuraSyncGroup

import Foundation

// MARK: - SakuraPrefs

/// Top-level prefs structure written by the app and read by the extension.
struct SakuraPrefs: Codable, Sendable {
    /// Global pause (affects all displays).
    var userPaused: Bool = false
    /// When true, video plays only on the lock screen — desktop is always paused.
    var alwaysPauseDesktop: Bool = false
    /// Pause when all windows are covering the wallpaper (occlusion detection).
    var pauseWhenOccluded: Bool = false
    /// Current occlusion state, updated by OcclusionMonitor in the app. Written
    /// to the prefs file so the extension knows without running its own occlusion check.
    var desktopOccluded: Bool = false
    /// Per-display manual pause (from "Pause this display" menu item).
    var pausedDisplays: Set<UInt32>?
    /// Per-display rotation config, keyed by display UUID string.
    var perDisplayConfig: [String: SakuraDisplayConfig] = [:]
    /// Sync groups: sets of displays that advance their playlist simultaneously.
    var syncGroups: [SakuraSyncGroup] = []
    /// Ordered history of recently-displayed video entry IDs (most recent first).
    /// Written by the app after user interaction; read by MenuBarView for the history menu.
    var wallpaperHistory: [String] = []
    /// What to show on a newly-connected display before the user has chosen a video.
    /// "blank" = show nothing; "inheritSyncGroup" = copy first sync group's current video.
    var newScreenPolicy: String = New_Screen_Policy.blank.rawValue
}

// MARK: - SakuraDisplayConfig

/// Per-display rotation configuration. One entry per display UUID in perDisplayConfig.
struct SakuraDisplayConfig: Codable, Sendable {
    /// UUID of the video entry currently set on this display (nil if folder mode, no selection yet).
    var entryID: String?
    /// How long to show each video before advancing. 0 = manual only.
    var rotationIntervalMinutes: Int = 15
    var isRotationEnabled: Bool = true
    /// When true, pick the next video randomly from the playlist instead of sequentially.
    var isShuffleMode: Bool = false
    /// Include videos in subdirectories of folderPath when building the playlist.
    var includeSubfolders: Bool = false
    /// When true, the playlist is built from folderPath rather than individual selected entries.
    var isFolderMode: Bool = false
    /// Absolute path to the folder to scan for videos (only used when isFolderMode = true).
    var folderPath: String?
    /// The sync group this display belongs to, if any. Matches SakuraSyncGroup.groupID.
    var syncGroupID: String?
}

// MARK: - SakuraSyncGroup

/// A set of displays that advance to the same playlist index simultaneously.
/// currentIndex and playlist are NOT in this struct — RotationEngine manages those
/// in-memory so a prefs write doesn't interrupt a running rotation.
struct SakuraSyncGroup: Codable, Sendable {
    var groupID: String
    /// Display UUID strings for every display in this group.
    var displayIDs: [String]
    var rotationIntervalMinutes: Int
    var isShuffleMode: Bool
}
