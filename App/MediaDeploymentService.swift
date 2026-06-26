// MediaDeploymentService.swift — deploy video files into the extension container.
// Adapted from Phosphene/VideoDeploymentService.swift.
// Changes: VideoDeploymentService → MediaDeploymentService, Video → Sakura naming,
//          HEVC conversion removed (not needed — we take the file as-is),
//          container bundle ID updated to com.sakura.wallpaper.extension,
//          Log.video → os.Logger.
//
// The extension is sandboxed and cannot call NSWorkspace file pickers or access
// arbitrary paths. The app holds security-scoped bookmarks to user-selected folders
// and copies files into the extension container so the extension can read them.

import AVFoundation
import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "com.sakura.wallpaper", category: "deployment")

enum MediaDeploymentService {

    // MARK: - Extension container path (app-side access)

    /// Documents directory of the extension container.
    /// The extension reads from this path (as ~/Documents); the app writes here.
    static var extensionDocsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.sakura.wallpaper.extension/Data/Documents")
    }

    // MARK: - Deploy

    /// Copy a video file into the extension's library directory structure.
    ///
    /// Creates:
    ///   `<extensionDocs>/videos/<uuid>/`
    ///   `<extensionDocs>/videos/<uuid>/<original-filename>`  — video file
    ///   `<extensionDocs>/videos/<uuid>/metadata.json`        — SakuraEntry metadata
    ///   `<extensionDocs>/videos/<uuid>/thumbnail.jpg`        — first-frame thumbnail
    ///
    /// Skips deployment if a video with the same filename already exists (dedup by filename).
    /// Posts com.sakura.wallpaper.libraryChanged Darwin notification after writing.
    @MainActor
    static func deployVideo(url: URL, name: String? = nil) async {
        let fm = FileManager.default
        let videosDir = extensionDocsURL.appendingPathComponent("videos")
        try? fm.createDirectory(at: videosDir, withIntermediateDirectories: true)

        // Dedup: skip if a video with the same filename is already in the library.
        let existing = listEntries()
        if existing.contains(where: { $0.filename == url.lastPathComponent }) {
            logger.info("Video '\(url.lastPathComponent)' already in library, skipping deploy")
            return
        }

        let id = UUID().uuidString
        let dir = videosDir.appendingPathComponent(id)

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let destURL = dir.appendingPathComponent(url.lastPathComponent)
            try fm.copyItem(at: url, to: destURL)

            // Probe the video so the library has accurate fps/duration/resolution.
            var fps: Double = 0
            var resolution: CGSize = .zero
            var duration: Double = 0
            let asset = AVURLAsset(url: destURL)
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                fps        = Double((try? await track.load(.nominalFrameRate)) ?? 0)
                resolution = (try? await track.load(.naturalSize)) ?? .zero
                let cmDur  = try? await asset.load(.duration)
                duration   = cmDur.map { CMTimeGetSeconds($0) } ?? 0
            }

            // Write metadata.json using the same Codable key layout as SakuraEntry.
            let metadata = EntryMetadata(
                id: id,
                name: name ?? url.deletingPathExtension().lastPathComponent,
                filename: url.lastPathComponent,
                duration: duration, fps: fps, resolution: resolution,
                dateAdded: Date(), variants: nil
            )
            let data = try JSONEncoder().encode(metadata)
            try data.write(to: dir.appendingPathComponent("metadata.json"))

            await generateThumbnail(for: destURL, in: dir)

            logger.info("Deployed '\(url.lastPathComponent)' as \(id)")
            notifyLibraryChanged()
        } catch {
            logger.error("Failed to deploy video: \(error.localizedDescription)")
            try? fm.removeItem(at: dir)
        }
    }

    // MARK: - Remove

    /// Remove a video entry from the extension container.
    static func removeVideo(entryID: String) {
        guard let dir = validatedEntryDir(entryID) else { return }
        try? FileManager.default.removeItem(at: dir)
        logger.info("Removed entry \(entryID) from extension container")
        notifyLibraryChanged()
    }

    // MARK: - Query

    /// List all valid video entries visible in the extension container.
    static func listEntries() -> [EntryInfo] {
        let videosDir = extensionDocsURL.appendingPathComponent("videos")
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(
            at: videosDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }

        var entries = [EntryInfo]()
        for dir in subdirs where dir.hasDirectoryPath {
            let metadataURL = dir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let entry = try? JSONDecoder().decode(EntryInfo.self, from: data)
            else { continue }
            let videoFile = dir.appendingPathComponent(entry.filename)
            guard fm.fileExists(atPath: videoFile.path) else { continue }
            entries.append(entry)
        }
        return entries.sorted { $0.dateAdded < $1.dateAdded }
    }

    /// URL to the video file for a library entry.
    static func videoURL(for entry: EntryInfo) -> URL {
        extensionDocsURL
            .appendingPathComponent("videos/\(entry.id)/\(entry.filename)")
    }

    /// URL to the thumbnail for an entry, if it exists.
    static func thumbnailURL(for entryID: String) -> URL? {
        let url = extensionDocsURL
            .appendingPathComponent("videos/\(entryID)/thumbnail.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Types

    /// Mirrors the Codable fields of SakuraEntry for app-side reads/writes without
    /// importing extension sources. Must stay in sync with SakuraEntry.CodingKeys.
    struct EntryInfo: Codable {
        let id: String
        var name: String
        var filename: String
        var duration: Double
        var fps: Double
        var resolution: CGSize
        var dateAdded: Date
        var variants: [SakuraVariant]?
    }

    // Private metadata struct used when writing new entries — same JSON layout as EntryInfo.
    private struct EntryMetadata: Codable {
        let id: String
        var name: String
        var filename: String
        var duration: Double
        var fps: Double
        var resolution: CGSize
        var dateAdded: Date
        var variants: [SakuraVariant]?
    }

    // MARK: - Private

    private static func validatedEntryDir(_ entryID: String) -> URL? {
        let videosDir = extensionDocsURL.appendingPathComponent("videos")
        let dir = videosDir.appendingPathComponent(entryID)
        guard PathSafety.isValidEntryID(entryID), PathSafety.contained(dir, in: videosDir) else {
            logger.error("Rejecting unsafe entry id: \(entryID)")
            return nil
        }
        return dir
    }

    @MainActor
    private static func generateThumbnail(for videoURL: URL, in directory: URL) async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        guard let (cgImage, _) = try? await generator.image(at: .zero) else {
            logger.error("Thumbnail generation failed for \(videoURL.lastPathComponent)")
            return
        }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            logger.error("Thumbnail JPEG encoding failed")
            return
        }

        let thumbURL = directory.appendingPathComponent("thumbnail.jpg")
        do {
            try jpeg.write(to: thumbURL, options: .atomic)
        } catch {
            logger.error("Thumbnail write failed: \(error.localizedDescription)")
        }
    }

    private static func notifyLibraryChanged() {
        // Darwin notification wakes the extension so it calls SakuraLibrary.shared.scan().
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(SakuraNotification.libraryChanged as CFString),
            nil, nil, true
        )
    }
}
