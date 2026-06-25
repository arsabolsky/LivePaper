// MARK: - [Phase 0] Xcode-free migration — now lives in SakuraWallpaperCore/Sources/SakuraWallpaperCore/
// NOTE: .image case and image extensions are kept here temporarily so the legacy App/ sources
// still compile during the port. Both will be removed in Phase 7 when App/ is fully rewritten.
import Foundation

enum MediaType: Equatable {
    case video, image, unsupported

    static func detect(_ url: URL) -> MediaType {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "gif", "m4v"].contains(ext) { return .video }
        // Image detection retained only for legacy App/ compatibility — removed in Phase 7.
        if ["png", "jpg", "jpeg", "heic", "heif", "webp", "bmp", "tiff"].contains(ext) { return .image }
        return .unsupported
    }
}
