// SakuraEntry.swift — video entry model for the extension's library.
// Adapted from PhospheneExtension/VideoLibrary.swift (VideoEntry struct).
// Changes: VideoEntry → SakuraEntry, VideoVariant → SakuraVariant (moved to Core),
//          added groupID and displayID runtime-only fields excluded from Codable.

import Foundation

/// One video in the managed library. Persisted as metadata.json in its entry directory.
///
/// `groupID` and `displayID` are runtime-only: RotationEngine sets them in-memory
/// when it knows which display/group is playing this entry. They are not serialized —
/// metadata.json only ever contains the static video attributes.
struct SakuraEntry: Codable, Sendable {
    let id: String          // UUID string — matches the directory name
    var name: String        // human-readable title (from filename by default)
    var filename: String    // basename of the video file; PathSafety.isSafeComponent validated on read
    var duration: Double    // seconds; 0 until probed by SakuraDiscovery
    var fps: Double         // nominal FPS; 0 until probed
    var resolution: CGSize
    var dateAdded: Date
    var variants: [SakuraVariant]?   // lower-FPS re-encodes for policy-driven rate control

    // Runtime state — set by RotationEngine, NOT written to metadata.json.
    // We use CodingKeys to exclude these from the Codable implementation.
    var groupID: String?    // which sync group is currently driving this entry
    var displayID: String?  // which display UUID is currently showing this entry

    // CodingKeys: excludes groupID and displayID so they are invisible to JSON encode/decode.
    enum CodingKeys: String, CodingKey {
        case id, name, filename, duration, fps, resolution, dateAdded, variants
    }
}
