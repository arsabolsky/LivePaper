// SakuraVariant.swift — video variant descriptor shared between app and extension.
// A variant is a re-encoded copy of a source video at a lower frame rate,
// used by SakuraPlaybackPolicy to reduce CPU/GPU load on battery or thermal pressure.
//
// Variants live alongside the source video in the library entry directory:
//   <videosDir>/<uuid>/video.mp4          — original
//   <videosDir>/<uuid>/variant_30fps.mp4  — SakuraPlaybackPolicy.reduced tier
//   <videosDir>/<uuid>/variant_15fps.mp4  — SakuraPlaybackPolicy.minimal tier

import Foundation

struct SakuraVariant: Codable, Sendable {
    let filename: String    // basename only — PathSafety.isSafeComponent validated on read
    let fps: Int
    let resolution: CGSize
}
