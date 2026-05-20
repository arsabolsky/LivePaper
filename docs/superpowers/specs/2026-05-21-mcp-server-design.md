# MCP Server for SakuraWallpaper — Design Spec

**Date**: 2026-05-21
**Status**: Approved

## Overview

Add an MCP (Model Context Protocol) server to SakuraWallpaper so AI agents (Claude Desktop, Cursor, Codex) can control wallpapers — set images/videos, switch folders, pause/resume, configure rotation, query status — through standardized tool calls. The MCP server and GUI app coexist: shared state via UserDefaults, real-time sync via DistributedNotificationCenter, and each works independently if the other is absent.

## Architecture

```
┌─────────────────┐     UserDefaults       ┌──────────────────┐
│ SakuraWallpaper  │◄────(shared state)────►│   sakura-mcp     │
│   (GUI App)      │                        │  (CLI, stdio)    │
│                  │  DistributedNotification│                  │
│  settings/play   │◄───(real-time sync)───►│  MCP Tools (9)   │
└─────────────────┘                        └──────┬───────────┘
                                                  │ stdio
                                          ┌───────▼───────────┐
                                          │  AI Agent         │
                                          │ (Claude/Cursor)   │
                                          └──────────────────┘
```

- **MCP CLI and GUI app are separate binaries**, independently runnable
- Shared state through the existing `UserDefaults` (no migration needed — `SettingsManager`/`Screen_Config` are already Codable and stored there)
- Real-time sync through `DistributedNotificationCenter` so GUI reflects MCP changes instantly (and vice versa)
- If only one is running, it works normally — no coupling

## Components

### 1. `SakuraWallpaperCore` (existing Package.swift)

Already defines a library target with `SettingsManager`, `Screen_Config`, `WallpaperBehavior`, `MediaType`, `PlaylistBuilder`, `AsyncWorkLimiter`. **No changes needed** — it already contains all the data models and business logic both sides need.

### 2. `sakura-mcp` (new SPM executable target)

- Added as a new `.executableTarget` in `Package.swift`, depending on `SakuraWallpaperCore`
- Entry point: `Sources/sakura-mcp/main.swift`
- Implements the MCP stdio transport (JSON-RPC over stdin/stdout)
- Registers 9 tools, dispatches to `WallpaperManager` (headless instance)

#### MCP Protocol

Standard MCP JSON-RPC 2.0 over stdio:
- `initialize` → capability negotiation
- `tools/list` → returns tool definitions
- `tools/call` → executes a tool, returns result

Error handling: JSON-RPC error codes with human-readable messages.

### 3. `WallpaperManager` (headless mode)

The existing `WallpaperManager` was designed for GUI use (it creates `ScreenPlayer` windows). For CLI use we need it to work without `NSApplication` running.

**Change**: Make `WallpaperManager` functional without `NSApp` — the player windows still work (they are borderless overlay windows), but no menu bar, no main window controller. This is safe because `ScreenPlayer` windows are created per-screen via `NSWindow` directly.

### 4. IPC: DistributedNotificationCenter

Both sides post and observe notifications:

| Notification | Payload | Direction |
|---|---|---|
| `SakuraWallpaperStateChanged` | screen ID, changed fields | bidirectional |
| `SakuraWallpaperWallpaperSet` | screen ID, path | bidirectional |
| `SakuraWallpaperPlaybackToggled` | paused: bool | bidirectional |

GUI app observes these to update its UI (status item, main window). MCP CLI observes these mainly to keep its internal state accurate (but doesn't strictly need to — UserDefaults is the source of truth).

## MCP Tools

### 1. `list_screens`
Returns all connected screens with their IDs, names, and resolutions.
```
Input:  none
Output: [{id: "uuid", name: "Built-in Retina Display", frame: {w, h, x, y}}]
```

### 2. `get_status`
Returns current wallpaper status for all screens or a specific one.
```
Input:  screen_id? (optional)
Output: {screens: [{id, folder_path?, wallpaper_path?, is_playing, is_paused, rotation_interval, shuffle, fit_mode}]}
```

### 3. `set_wallpaper`
Sets a single image or video as wallpaper on one or all screens.
```
Input:  file_path (required), screen_id? (optional, default: all)
Output: {success: true, screen_id, file_path}
```

### 4. `set_folder`
Sets a folder for wallpaper rotation on one or all screens.
```
Input:  folder_path (required), screen_id? (optional, default: all),
        rotation_interval_minutes? (default: current or 15),
        shuffle? (default: current or false),
        include_subfolders? (default: current or false),
        fit_mode? (default: current or "fill")
Output: {success: true, screen_id, folder_path, file_count}
```

### 5. `stop_wallpaper`
Stops wallpaper playback on one or all screens.
```
Input:  screen_id? (optional, default: all)
Output: {success: true, stopped_screens: ["id1", "id2"]}
```

### 6. `pause_resume`
Pauses or resumes wallpaper playback globally.
```
Input:  action ("pause" | "resume" | "toggle")
Output: {paused: true/false}
```

### 7. `next_wallpaper`
Advances to the next wallpaper in the rotation for one or all screens.
```
Input:  screen_id? (optional, default: all)
Output: {success: true, screen_id, new_file}
```

### 8. `get_settings`
Reads current configuration for one or all screens.
```
Input:  screen_id? (optional)
Output: {screens: [{id, folder_path?, wallpaper_path?, rotation_interval, shuffle, include_subfolders, fit_mode, is_synced}]}
```

### 9. `update_settings`
Updates configuration parameters without changing the current wallpaper.
```
Input:  screen_id? (optional, default: all),
        rotation_interval_minutes?,
        shuffle?,
        include_subfolders?,
        fit_mode?,
        is_synced?
Output: {success: true, screen_id, updated_fields: [...]}
```

## Data Flow

### User says "set my wallpaper to a sunset image"

```
AI Agent                          sakura-mcp                     macOS
   │                                  │                            │
   ├─ tools/call: set_wallpaper ─────►│                            │
   │     file_path: /tmp/sunset.jpg   │                            │
   │                                  ├─ MediaType.detect()       │
   │                                  ├─ WallpaperManager         │
   │                                  │   .setWallpaper(url,      │
   │                                  │    for: screen)           │
   │                                  ├─ SettingsManager          │
   │                                  │   .setScreenConfig()      │
   │                                  ├─ DistributedNotification  │
   │                                  │   StateChanged ────────► (GUI app updates UI)
   │◄──── {success: true} ────────────│                            │
```

### AI downloads a file, then sets it

The AI agent is responsible for downloading — `sakura-mcp` only accepts local file paths. The AI:
1. Uses its own tools/internet access to find/download an image
2. Saves it to a temp directory
3. Calls `set_wallpaper(file_path: "/tmp/downloaded.jpg")`

## Error Handling

| Scenario | Behavior |
|---|---|
| File not found | Return error with message "File not found: {path}" |
| Unsupported format | Return error with supported format list |
| Screen ID not found | Return error "Screen not found: {id}" |
| GUI app not running | MCP works independently (no sync needed) |
| MCP CLI not running | GUI app works independently |
| Folder empty (no media files) | Return success with `file_count: 0` and warning |

## Security

- MCP CLI runs locally, only accepts stdio connections from the parent process (the AI agent)
- No network listener — stdio transport is inherently local
- File paths are validated to exist and be readable before acting
- Security-scoped bookmarks (implemented separately) apply to MCP operations too

## Testing

- Unit tests: each tool's input validation, error paths
- Integration test: launch `sakura-mcp`, send JSON-RPC over pipe, verify file operations
- Manual: configure in Claude Desktop `claude_desktop_config.json`, test each tool interactively

## Key Risk: Headless WallpaperManager

`ScreenPlayer` creates `NSWindow` instances for video/image display. In a headless CLI context:
- `NSApplication` must be initialized (minimally) for windowing to work
- The process must not exit while players are active (run loop required)
- `AppDelegate` / `MainWindowController` dependencies must be optional

**Mitigation**: `sakura-mcp` will bootstrap a minimal `NSApplication` (no dock icon, no menu bar — `LSUIElement`-style) before registering MCP handlers. This is standard practice for CLI tools that need windowing (e.g., `screencapture`, `sips`).

## Implementation Plan (high-level)

1. **Refactor `WallpaperManager`** for headless operation (remove `NSApp` / `MainWindowController` dependency, make those optional)
2. **Add `sakura-mcp` target** to `Package.swift` (`.executableTarget`, depends on `SakuraWallpaperCore`)
3. **Implement MCP stdio transport** (JSON-RPC parse/dispatch loop)
4. **Implement 9 tools** one by one
5. **Add DistributedNotificationCenter sync**
6. **Create Claude Desktop config template** (`docs/mcp-config.json`)
7. **Write tests**
8. **Build via `swift build --product sakura-mcp`** (separate from `build.sh` which builds the GUI app)
