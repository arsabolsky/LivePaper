import Cocoa
import SakuraWallpaperCore

// Detect GUI session: NSScreen.screens returns empty when no window server (SSH/CI).
// When launched from terminal within a GUI session or from Claude Desktop, it works.
// Use NSApplication.shared instead of NSApp — the latter crashes in SPM-built binaries.
let hasGUI = !NSScreen.screens.isEmpty

var wallpaperManager: WallpaperManager?
if hasGUI {
    NSApplication.shared.setActivationPolicy(.accessory)
    wallpaperManager = WallpaperManager()
    wallpaperManager?.restoreAllScreens()
}

let server = MCPServer(wallpaperManager: wallpaperManager)

IPCSync.observeStateChanges { _ in }

server.run()

if hasGUI {
    RunLoop.main.run()
}
