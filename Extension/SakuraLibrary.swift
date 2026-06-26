// SakuraLibrary.swift — manages the video library in the extension's Documents container.
// Adapted from PhospheneExtension/VideoLibrary.swift.
// Changes: VideoLibrary → SakuraLibrary, VideoEntry → SakuraEntry, VideoVariant → SakuraVariant,
//          PlaybackPolicy → SakuraPlaybackPolicy, log prefix updated.
//
// Videos are stored in `~/Documents/videos/<uuid>/` with metadata.json alongside
// the video file. A top-level `library.json` serves as a quick-access index.
// From within the sandboxed extension process, `homeDirectoryForCurrentUser` resolves
// to the extension container — no need to hardcode the container path here.
//
// The library is the source of truth for what videos are available to the extension.
// The app manages the same directory from outside via MediaDeploymentService.

import AVFoundation
import Foundation
import ImageIO
import os

final class SakuraLibrary: Sendable {
    static let shared = SakuraLibrary()

    private let videosDir: URL
    private let indexURL: URL
    private let lock = OSAllocatedUnfairLock(initialState: [SakuraEntry]())

    private init() {
        // Within the sandboxed extension, homeDirectory = container Documents dir.
        let docs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        self.videosDir = docs.appendingPathComponent("videos")
        self.indexURL  = docs.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    var entries: [SakuraEntry] {
        lock.withLock { $0 }
    }

    func entry(for id: String) -> SakuraEntry? {
        lock.withLock { entries in entries.first { $0.id == id } }
    }

    /// Absolute URL to the video file for a given entry.
    func videoURL(for entry: SakuraEntry) -> URL {
        videosDir.appendingPathComponent(entry.id).appendingPathComponent(entry.filename)
    }

    func videoURL(for id: String) -> URL? {
        guard let entry = entry(for: id) else { return nil }
        return videoURL(for: entry)
    }

    func variantURL(for entryId: String, variant: SakuraVariant) -> URL {
        videosDir.appendingPathComponent(entryId).appendingPathComponent(variant.filename)
    }

    /// Select the variant URL best matching the current playback policy.
    ///
    /// Falls back to the original file if no variants are available.
    /// Returns nil only when the entry itself doesn't exist.
    func bestVariantURL(for id: String, policy: SakuraPlaybackPolicy) -> URL? {
        guard let entry = entry(for: id) else { return nil }
        guard let variants = entry.variants, !variants.isEmpty else {
            return videoURL(for: entry)
        }
        let sorted = variants.sorted { $0.fps > $1.fps }
        let chosen: SakuraVariant
        switch policy {
        case .paused: return videoURL(for: entry)
        case .full:   chosen = sorted.first!
        case .minimal: chosen = sorted.last!
        case .reduced:
            let mid = sorted.count / 2
            chosen = sorted[mid]
        }
        return variantURL(for: id, variant: chosen)
    }

    // MARK: - Scan

    /// Scan the videos directory and rebuild the in-memory entry list.
    /// Prunes entries whose video file has been deleted.
    /// Migrates any legacy `wallpaper.{mp4,mov,m4v}` from the Documents root.
    func scan() {
        migrateLegacyVideo()

        var discovered = [SakuraEntry]()
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(
            at: videosDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else {
            lock.withLock { $0 = [] }
            saveIndex([])
            return
        }

        for dir in subdirs where dir.hasDirectoryPath {
            let id = dir.lastPathComponent

            // Only process UUID-named directories. Anything else is a stray file
            // or user artifact — skip (never delete) so a corrupt library can't
            // accidentally trigger a removal outside the tree.
            guard PathSafety.isValidEntryID(id) else {
                extensionLog("[SakuraLibrary] Skipping non-UUID directory: \(id)")
                continue
            }

            let metadataURL = dir.appendingPathComponent("metadata.json")

            if let data = try? Data(contentsOf: metadataURL),
               let entry = try? JSONDecoder().decode(SakuraEntry.self, from: data) {
                // Defensive: metadata id must match its directory, and filename must
                // be a safe basename — guards against a hand-edited metadata.json
                // steering a file op outside the videos/ tree.
                guard entry.id == id, PathSafety.isSafeComponent(entry.filename) else {
                    extensionLog("[SakuraLibrary] Quarantining \(id): id/filename mismatch or unsafe")
                    continue
                }
                let videoFile = dir.appendingPathComponent(entry.filename)
                guard PathSafety.contained(videoFile, in: videosDir) else {
                    extensionLog("[SakuraLibrary] Quarantining \(id): video path escapes library")
                    continue
                }
                guard fm.fileExists(atPath: videoFile.path) else {
                    extensionLog("[SakuraLibrary] Pruning orphaned entry \(id): video file missing")
                    try? fm.removeItem(at: dir)
                    continue
                }
                discovered.append(sanitizingVariants(entry))
            } else if let videoFile = findVideoFile(in: dir) {
                // Entry directory with no metadata.json — synthesize a minimal entry.
                let entry = SakuraEntry(
                    id: id,
                    name: videoFile.deletingPathExtension().lastPathComponent,
                    filename: videoFile.lastPathComponent,
                    duration: 0, fps: 0, resolution: .zero,
                    dateAdded: Date(), variants: nil,
                    groupID: nil, displayID: nil
                )
                discovered.append(entry)
                try? JSONEncoder().encode(entry).write(to: metadataURL)
            } else {
                extensionLog("[SakuraLibrary] Pruning empty directory \(id): no video file found")
                try? fm.removeItem(at: dir)
            }
        }

        discovered.sort { $0.dateAdded < $1.dateAdded }
        let sorted = discovered  // local copy avoids captured-var warning under strict concurrency
        lock.withLock { $0 = sorted }
        saveIndex(sorted)
        extensionLog("[SakuraLibrary] Scanned: \(sorted.count) video(s)")
    }

    // MARK: - Mutation

    /// Update duration/fps/resolution metadata for an entry after probing.
    func updateMetadata(for id: String, duration: Double, fps: Double, resolution: CGSize) {
        lock.withLock { entries in
            guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[idx].duration = duration
            entries[idx].fps = fps
            entries[idx].resolution = resolution
        }
        persistMetadata(for: id)
    }

    func updateVariants(for id: String, variants: [SakuraVariant]) {
        lock.withLock { entries in
            guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[idx].variants = variants
        }
        persistMetadata(for: id)
        saveIndex(entries)
    }

    func removeVideo(id: String) {
        let dir = videosDir.appendingPathComponent(id)
        guard PathSafety.isValidEntryID(id), PathSafety.contained(dir, in: videosDir) else {
            extensionLog("[SakuraLibrary] Refusing to remove unsafe id: \(id)")
            return
        }
        try? FileManager.default.removeItem(at: dir)
        lock.withLock { $0.removeAll { $0.id == id } }
        saveIndex(entries)
        extensionLog("[SakuraLibrary] Removed: \(id)")
    }

    // MARK: - Thumbnail

    /// Generate a JPEG thumbnail from the video's first frame, saved as thumbnail.jpg
    /// in the entry directory. Returns the thumbnail URL on success, nil on failure.
    func generateThumbnail(for entry: SakuraEntry) async -> URL? {
        let url = videoURL(for: entry)
        let thumbURL = videosDir
            .appendingPathComponent(entry.id)
            .appendingPathComponent("thumbnail.jpg")

        if FileManager.default.fileExists(atPath: thumbURL.path) {
            return thumbURL
        }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)

        guard let (cgImage, _) = try? await generator.image(at: .zero) else {
            extensionLog("[SakuraLibrary] Thumbnail failed for \(entry.id)")
            return nil
        }

        guard let dest = CGImageDestinationCreateWithURL(
            thumbURL as CFURL, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return thumbURL
    }

    // MARK: - Private

    private func saveIndex(_ entries: [SakuraEntry]) {
        try? JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
    }

    private func persistMetadata(for id: String) {
        guard let entry = entry(for: id) else { return }
        let metadataURL = videosDir.appendingPathComponent(id).appendingPathComponent("metadata.json")
        try? JSONEncoder().encode(entry).write(to: metadataURL)
    }

    /// Drop any variants whose filename isn't a safe basename so a corrupt
    /// metadata.json can't steer a file op to an out-of-tree path.
    private func sanitizingVariants(_ entry: SakuraEntry) -> SakuraEntry {
        guard let variants = entry.variants else { return entry }
        let safe = variants.filter { PathSafety.isSafeComponent($0.filename) }
        guard safe.count != variants.count else { return entry }
        extensionLog("[SakuraLibrary] Dropped \(variants.count - safe.count) unsafe variant(s) from \(entry.id)")
        var copy = entry
        copy.variants = safe.isEmpty ? nil : safe
        return copy
    }

    private func findVideoFile(in directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }
        return contents.first { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
    }

    /// Migrate a legacy `wallpaper.{mp4,mov,m4v}` from Documents root into the library.
    /// The original SakuraWallpaper stored a single file there before multi-library support.
    private func migrateLegacyVideo() {
        let docs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents")
        let fm   = FileManager.default
        for ext in ["mp4", "mov", "m4v"] {
            let legacyURL = docs.appendingPathComponent("wallpaper.\(ext)")
            guard fm.fileExists(atPath: legacyURL.path) else { continue }
            let id = UUID().uuidString
            let dir = videosDir.appendingPathComponent(id)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent("wallpaper.\(ext)")
                try fm.moveItem(at: legacyURL, to: dest)
                let entry = SakuraEntry(
                    id: id, name: "Wallpaper", filename: "wallpaper.\(ext)",
                    duration: 0, fps: 0, resolution: .zero, dateAdded: Date(), variants: nil,
                    groupID: nil, displayID: nil
                )
                try JSONEncoder().encode(entry).write(to: dir.appendingPathComponent("metadata.json"))
                extensionLog("[SakuraLibrary] Migrated legacy wallpaper.\(ext) → \(id)")
            } catch {
                extensionLog("[SakuraLibrary] Migration failed: \(error)")
                try? fm.removeItem(at: dir)
            }
            break // migrate at most one legacy file per scan
        }
    }
}
