// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LivePaperCore",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "LivePaperCore", targets: ["LivePaperCore"])
    ],
    targets: [
        .target(
            name: "LivePaperCore",
            path: ".",
            exclude: [
                "Resources",
                "img",
                "build",
                "docs",
                "Tests",
                "AppDelegate.swift",
                "MainWindowController.swift",
                "ScreenPlayer.swift",
                "WallpaperManager.swift",
                "ThumbnailItem.swift",
                "ThumbnailProvider.swift",
                "Localization.swift",
                "PerformanceMonitor.swift",
                "AboutWindowController.swift",
                "main.swift",
                "AppIcon.icns",
                "README.md",
                "LICENSE",
                "build.sh"
            ],
            sources: [
                "Screen_Config.swift",
                "SettingsManager.swift",
                "MediaType.swift",
                "PlaylistBuilder.swift",
                "PausePolicy.swift",
                "PauseEvaluator.swift",
                "PauseCoordinator.swift"
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "LivePaperCoreTests",
            dependencies: ["LivePaperCore"],
            path: "Tests/LivePaperCoreTests"
        )
    ]
)
