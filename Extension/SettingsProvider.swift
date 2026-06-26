// SettingsProvider.swift — builds the WallpaperSettingsViewModelsXPC that populates
// the System Settings wallpaper picker. Adapted from PhospheneExtension/SettingsProvider.swift.
// Changes: VideoLibrary → SakuraLibrary, bundle-ID fallback and group name → Sakura.
//
// THIS is what makes our wallpapers appear in the picker. provideSettingsViewModels()
// returns the object built here; each library video becomes one SettingsItem carrying a
// ChoiceDescriptor whose `configuration` is the video UUID — the exact bytes that come
// back in acquire()'s request descriptor when the user clicks the thumbnail.

import AppKit
import Foundation

/// Build a fully-populated WallpaperSettingsViewModelsXPC using the Codable shims.
/// Creates one SettingsItem per video in the library.
func buildSettingsViewModelsXPC() async -> AnyObject? {
    let bundleID = Bundle.main.bundleIdentifier ?? "com.sakura.wallpaper.extension"
    let library = SakuraLibrary.shared
    let groupID = GroupID(id: "video-wallpapers")

    // Always re-scan so deletions / new deployments are reflected immediately.
    library.scan()

    let entries = library.entries

    var items = [SettingsItem]()

    for entry in entries {
        let videoURL = library.videoURL(for: entry)
        let choiceID = ChoiceID(
            id: entry.id,
            descriptor: ChoiceIDDescriptor(
                provider: ChoiceProviderID(rawValue: bundleID),
                identifier: entry.id,
                files: [videoURL],
                configuration: Data(entry.id.utf8)
            )
        )

        // Generate the thumbnail — skip the entry if extraction fails (no thumbnail = no choice).
        guard let thumbnailURL = await library.generateThumbnail(for: entry) else {
            continue
        }

        let choiceDescriptor = ChoiceDescriptor(
            id: choiceID,
            provider: ChoiceProviderID(rawValue: bundleID),
            identifier: entry.id,
            name: entry.name,
            localizedDescription: "Animated video wallpaper",
            thumbnail: .image(url: thumbnailURL),
            isDownloaded: true,
            options: []
        )

        let item = SettingsItem(
            id: choiceID,
            localizedName: entry.name,
            thumbnail: .image(url: thumbnailURL),
            choice: choiceDescriptor,
            contentBadge: .video,
            showInTopLevel: true,
            sortOrder: 0,
            disposability: .removable
        )
        items.append(item)
    }

    let group = SettingsGroup(
        id: groupID,
        items: items,
        localizedName: "SakuraWallpaper \u{2014} Video Wallpapers",
        disposability: .none,
        sortOrder: -100,
        // Mimic the Aerials group's sort identity so our section sits near the top.
        sortID: GroupSortID(id: "com.apple.wallpaper.aerials"),
        allChoiceID: nil,
        shouldHideItemLabels: false,
        contextMenu: nil,
        thumbnail: nil
    )

    let viewModel = SettingsViewModel(
        groups: [group],
        refreshPolicy: .default,
        isModificationDisabled: false
    )

    let viewModels = SettingsViewModels(
        desktop: viewModel,
        screenSaver: nil
    )

    return remapToRealXPC(viewModels)
}

/// Fallback: a WallpaperSettingsViewModelsXPC with empty groups (never return nil to the picker).
func makeEmptyGroupsResponse() -> AnyObject? {
    let emptyViewModels = SettingsViewModels(
        desktop: SettingsViewModel(
            groups: [],
            refreshPolicy: .default,
            isModificationDisabled: false
        ),
        screenSaver: nil
    )
    return remapToRealXPC(emptyViewModels)
}

/// Archive via ShimViewModelsXPC, then remap the class name on unarchive to the real XPC type.
///
/// Secure coding cannot be required here: the whole point is to archive our own
/// `ShimViewModelsXPC` and decode it back as the private `WallpaperSettingsViewModelsXPC`
/// via `setClass(_:forClassName:)` — a substitution secure coding is designed to forbid.
/// This is safe because the archive is never persisted or received over any boundary: it is
/// produced and consumed in-process within this one function from values we just built.
private func remapToRealXPC(_ viewModels: SettingsViewModels) -> AnyObject? {
    let shimXPC = ShimViewModelsXPC(value: viewModels)

    let data: Data
    do {
        data = try NSKeyedArchiver.archivedData(withRootObject: shimXPC, requiringSecureCoding: false)
    } catch {
        extensionLog("  [Remap] Archive failed: \(error)")
        return nil
    }

    guard let realClass = objc_getClass("WallpaperSettingsViewModelsXPC") as? AnyClass else {
        extensionLog("  [Remap] WallpaperSettingsViewModelsXPC class not found")
        return nil
    }

    guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
        extensionLog("  [Remap] Failed to create unarchiver")
        return nil
    }
    unarchiver.requiresSecureCoding = false
    unarchiver.decodingFailurePolicy = .setErrorAndReturn
    unarchiver.setClass(realClass, forClassName: "ShimViewModelsXPC")

    let result = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    if let error = unarchiver.error {
        extensionLog("  [Remap] Unarchive error: \(error)")
    }
    unarchiver.finishDecoding()

    if result == nil {
        extensionLog("  [Remap] Decoded result is nil")
    }
    return result as AnyObject?
}
