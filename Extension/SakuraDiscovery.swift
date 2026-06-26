// SakuraDiscovery.swift — video URL resolution and thumbnail generation.
// Adapted from PhospheneExtension/VideoDiscovery.swift.
// Changes: VideoLibrary → SakuraLibrary, WallpaperState → SakuraExtensionState.
//
// Each rendering context owns its own choice (videoID from acquire) — never use
// the process-wide currentVideoID on the rendering path or concurrent acquires for
// different displays will race. The currentVideoID fallback is for snapshot/settings
// requests that don't carry a per-context choice.

import AVFoundation
import Foundation
import ImageIO

/// Resolve a video URL for a specific choice ID.
///
/// Falls back to: first library entry → bundle resource `wallpaper.*`. Returns nil only
/// when all fallbacks are exhausted and nothing can be displayed.
func findVideoURL(forChoice videoID: String?) -> URL? {
    if let videoID,
       let url = SakuraLibrary.shared.videoURL(for: videoID),
       FileManager.default.fileExists(atPath: url.path) {
        return url
    }

    // Fallback 1: first available video in the library.
    if let first = SakuraLibrary.shared.entries.first {
        let url = SakuraLibrary.shared.videoURL(for: first)
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
    }

    // Fallback 2: bundled demo video (not present in Release builds, but useful in dev).
    for ext in ["mp4", "mov", "m4v"] {
        if let url = Bundle.main.url(forResource: "wallpaper", withExtension: ext) {
            return url
        }
    }

    return nil
}

/// Convenience wrapper for snapshot/settings calls that don't carry a per-context choice.
/// Uses the last user-picked video as a best-effort hint.
/// Do NOT use this on the rendering path — always pass the per-context choice there.
func findVideoURL() -> URL? {
    findVideoURL(forChoice: SakuraExtensionState.shared.currentVideoID)
}

/// Generate (or re-use a cached) JPEG thumbnail from a video's first frame.
/// The thumbnail is written alongside the video in its library entry directory.
///
/// Used by SakuraXPCHandler.provideSettingsViewModels and snapshot().
func generateThumbnail(from videoURL: URL) async -> URL? {
    // Locate the entry for this URL so we can use the library's standard thumbnail path.
    // If the URL isn't in the library (e.g. from the bundle fallback), write to Documents root.
    let docsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
    let thumbnailURL = docsDir.appendingPathComponent("thumbnail.jpg")

    if FileManager.default.fileExists(atPath: thumbnailURL.path) {
        return thumbnailURL
    }

    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 480, height: 270)

    guard let (cgImage, _) = try? await generator.image(at: .zero) else {
        extensionLog("[SakuraDiscovery] Thumbnail generation failed for \(videoURL.lastPathComponent)")
        return nil
    }

    try? FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)

    guard let dest = CGImageDestinationCreateWithURL(
        thumbnailURL as CFURL, "public.jpeg" as CFString, 1, nil
    ) else {
        extensionLog("[SakuraDiscovery] Thumbnail: failed to create image destination")
        return nil
    }
    CGImageDestinationAddImage(dest, cgImage, [
        kCGImageDestinationLossyCompressionQuality: 0.85
    ] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        extensionLog("[SakuraDiscovery] Thumbnail: failed to finalize")
        return nil
    }

    extensionLog("[SakuraDiscovery] Thumbnail saved: \(thumbnailURL.path)")
    return thumbnailURL
}
