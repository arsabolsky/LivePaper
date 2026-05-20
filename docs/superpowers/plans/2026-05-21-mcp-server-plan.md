# SakuraWallpaper MCP Server — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a headless MCP CLI (`sakura-mcp`) that lets AI agents control SakuraWallpaper — set wallpapers, manage folders, pause/resume, read status — via 9 tools over stdio JSON-RPC.

**Architecture:** The MCP CLI and GUI app share `SettingsManager`/`WallpaperManager`/`ScreenPlayer` (moved into `SakuraWallpaperCore` SPM target). They communicate via `UserDefaults` (shared state) + `DistributedNotificationCenter` (real-time sync). Each works independently if the other is absent.

**Tech Stack:** Swift 6.2, MCP stdio transport (JSON-RPC 2.0), SPM, DistributedNotificationCenter, UserDefaults suite.

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `Package.swift` | Modify | Add `sakura-mcp` target, expand Core sources |
| `WallpaperManager.swift` | Modify | Guard `NSApp` notification observers for headless |
| `Sources/sakura-mcp/main.swift` | Create | Entry point: bootstrap NSApp, start MCP server |
| `Sources/sakura-mcp/MCPServer.swift` | Create | JSON-RPC stdio transport + tool dispatch |
| `Sources/sakura-mcp/ToolRegistry.swift` | Create | Tool definitions and handler registration |
| `Sources/sakura-mcp/Tools/ListScreensTool.swift` | Create | `list_screens` |
| `Sources/sakura-mcp/Tools/GetStatusTool.swift` | Create | `get_status` |
| `Sources/sakura-mcp/Tools/SetWallpaperTool.swift` | Create | `set_wallpaper` |
| `Sources/sakura-mcp/Tools/SetFolderTool.swift` | Create | `set_folder` |
| `Sources/sakura-mcp/Tools/StopWallpaperTool.swift` | Create | `stop_wallpaper` |
| `Sources/sakura-mcp/Tools/PauseResumeTool.swift` | Create | `pause_resume` |
| `Sources/sakura-mcp/Tools/NextWallpaperTool.swift` | Create | `next_wallpaper` |
| `Sources/sakura-mcp/Tools/GetSettingsTool.swift` | Create | `get_settings` |
| `Sources/sakura-mcp/Tools/UpdateSettingsTool.swift` | Create | `update_settings` |
| `Sources/sakura-mcp/IPCSync.swift` | Create | DistributedNotificationCenter sync |
| `docs/mcp-config.json` | Create | Claude Desktop config template |
| `Tests/sakura-mcpTests/` | Create | Integration tests |

---

### Task 1: Expand SPM Core Target

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add WallpaperManager, ScreenPlayer, ThumbnailItem, ThumbnailProvider to Core sources**

These files have no dependency on AppDelegate/MainWindowController. Adding them to the SPM Core target makes them available to the MCP CLI.

Edit `Package.swift` — in the `SakuraWallpaperCore` target:
- Remove `ScreenPlayer.swift`, `WallpaperManager.swift`, `ThumbnailItem.swift`, `ThumbnailProvider.swift` from `exclude`
- Add them to `sources`
- Add `Localization.swift` and `PerformanceMonitor.swift` to sources (they're needed by ScreenPlayer/WallpaperManager)

```swift
.target(
    name: "SakuraWallpaperCore",
    path: ".",
    exclude: [
        "Resources",
        "img",
        "build",
        "docs",
        "Tests",
        "AppDelegate.swift",
        "MainWindowController.swift",
        "AboutWindowController.swift",
        "main.swift",
        "AppIcon.icns",
        "bg.jpg",
        "README.md",
        "README_CN.md",
        "LICENSE",
        "build.sh",
        "reset.sh",
        "SakuraWallpaper.dmg"
    ],
    sources: [
        "Screen_Config.swift",
        "SettingsManager.swift",
        "WallpaperBehavior.swift",
        "MediaType.swift",
        "PlaylistBuilder.swift",
        "AsyncWorkLimiter.swift",
        "Localization.swift",
        "PerformanceMonitor.swift",
        "ScreenPlayer.swift",
        "WallpaperManager.swift",
        "ThumbnailItem.swift",
        "ThumbnailProvider.swift"
    ],
    linkerSettings: [
        .linkedFramework("Cocoa"),
        .linkedFramework("AVKit"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("ServiceManagement"),
        .linkedFramework("ImageIO"),
        .linkedFramework("IOKit")
    ]
)
```

- [ ] **Step 2: Add sakura-mcp executable target to Package.swift**

```swift
products: [
    .library(name: "SakuraWallpaperCore", targets: ["SakuraWallpaperCore"]),
    .executable(name: "sakura-mcp", targets: ["sakura-mcp"])
],
targets: [
    // ... existing SakuraWallpaperCore target ...

    .executableTarget(
        name: "sakura-mcp",
        dependencies: ["SakuraWallpaperCore"],
        path: "Sources/sakura-mcp"
    ),

    // ... existing test target ...
]
```

- [ ] **Step 3: Build to verify Core target compiles**

```bash
swift build --target SakuraWallpaperCore
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Package.swift
git commit -m "build: expand SPM Core target with WallpaperManager, ScreenPlayer, Thumbnail modules"
```

---

### Task 2: Make WallpaperManager Headless-Compatible

**Files:**
- Modify: `WallpaperManager.swift:50-65`

- [ ] **Step 1: Guard NSApp notification observers**

`WallpaperManager` observes `NSApplication.didChangeScreenParametersNotification` and `NSApplication.didBecomeActiveNotification`. In headless mode, `NSApp` exists but these notifications may fire differently. The observers themselves are fine — they just need `NSApp` to be initialized. No code change needed for existing observers, but we wrap them in a check so the manager can be created before `NSApp` is ready.

Actually, these observers are set up in `init()`. In headless mode, `NSApp` will be initialized before `WallpaperManager` is created (we do that in `main.swift`). So **no change needed** — the existing code already works.

**Skip this task** — WallpaperManager requires no changes for headless operation.

---

### Task 3: Create sakura-mcp Entry Point

**Files:**
- Create: `Sources/sakura-mcp/main.swift`

- [ ] **Step 1: Write main.swift — bootstrap NSApp, create WallpaperManager, start MCP server**

```swift
import Cocoa
import SakuraWallpaperCore

// Minimal NSApplication bootstrap for ScreenPlayer windowing.
// No dock icon, no menu bar — runs as background agent.
NSApp.setActivationPolicy(.accessory)

let wallpaperManager = WallpaperManager()

// Restore previously configured wallpapers
wallpaperManager.restoreAllScreens()

// Start MCP stdio server on stdin/stdout
let server = MCPServer(wallpaperManager: wallpaperManager)
server.run()

// Keep run loop alive while MCP server is active
RunLoop.main.run()
```

- [ ] **Step 2: Build skeleton to verify it compiles (will fail — MCPServer not defined yet)**

```bash
swift build --target sakura-mcp 2>&1 | head -5
```

Expected: `error: cannot find type 'MCPServer' in scope`

- [ ] **Step 3: Commit**

```bash
git add Sources/sakura-mcp/main.swift
git commit -m "feat(mcp): add sakura-mcp entry point skeleton"
```

---

### Task 4: Implement MCP Stdio Transport

**Files:**
- Create: `Sources/sakura-mcp/MCPServer.swift`
- Create: `Sources/sakura-mcp/ToolRegistry.swift`

- [ ] **Step 1: Write MCPServer.swift — JSON-RPC 2.0 stdio loop**

```swift
import Foundation
import SakuraWallpaperCore

final class MCPServer {
    private let wallpaperManager: WallpaperManager
    private let registry = ToolRegistry()
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    init(wallpaperManager: WallpaperManager) {
        self.wallpaperManager = wallpaperManager
        registry.registerAll(wallpaperManager: wallpaperManager)
    }

    func run() {
        // Disable stdin buffering
        setbuf(stdin, nil)
        setbuf(stdout, nil)

        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let message = try? decoder.decode(JSONRPCMessage.self, from: data) else {
                continue
            }
            handle(message)
        }
    }

    private func handle(_ message: JSONRPCMessage) {
        switch message {
        case .request(let id, let method, let params):
            switch method {
            case "initialize":
                send(.response(id: id, result: .object([
                    "protocolVersion": .string("2024-11-05"),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object([
                        "name": .string("sakura-mcp"),
                        "version": .string("1.0.0")
                    ])
                ])))
            case "tools/list":
                send(.response(id: id, result: .object([
                    "tools": .array(registry.toolDefinitions.map { $0.json })
                ])))
            case "tools/call":
                guard let toolName = params?["name"]?.stringValue,
                      let arguments = params?["arguments"]?.objectValue else {
                    send(.error(id: id, code: -32602, message: "Invalid params"))
                    return
                }
                do {
                    let result = try registry.invoke(name: toolName, arguments: arguments)
                    send(.response(id: id, result: result))
                } catch let error as MCPToolError {
                    send(.error(id: id, code: -32000, message: error.message))
                } catch {
                    send(.error(id: id, code: -32603, message: error.localizedDescription))
                }
            default:
                send(.error(id: id, code: -32601, message: "Method not found: \(method)"))
            }
        case .notification(let method, _):
            // Ignore notifications (e.g., initialized, cancelled)
            if method == "notifications/initialized" {
                // Session ready — no response needed per MCP spec
            }
        }
    }

    private func send(_ message: JSONRPCMessage) {
        guard let data = try? encoder.encode(message),
              let json = String(data: data, encoding: .utf8) else { return }
        print(json)
        fflush(stdout)
    }
}

// MARK: - JSON-RPC types

indirect enum JSONRPCValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONRPCValue])
    case array([JSONRPCValue])
    case null

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var objectValue: [String: JSONRPCValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let o = try? container.decode([String: JSONRPCValue].self) { self = .object(o) }
        else if let a = try? container.decode([JSONRPCValue].self) { self = .array(a) }
        else if container.decodeNil() { self = .null }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}

enum JSONRPCMessage: Codable {
    case request(id: String, method: String, params: [String: JSONRPCValue]?)
    case response(id: String, result: JSONRPCValue)
    case error(id: String?, code: Int, message: String)
    case notification(method: String, params: [String: JSONRPCValue]?)

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }
    enum ErrorKeys: String, CodingKey {
        case code, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let method = try container.decodeIfPresent(String.self, forKey: .method)
        let id = try container.decodeIfPresent(String.self, forKey: .id)

        if let method = method {
            if let id = id {
                let params = try container.decodeIfPresent([String: JSONRPCValue].self, forKey: .params)
                self = .request(id: id, method: method, params: params)
            } else {
                let params = try container.decodeIfPresent([String: JSONRPCValue].self, forKey: .params)
                self = .notification(method: method, params: params)
            }
        } else if let id = id {
            if container.contains(.error) {
                let errContainer = try container.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
                let code = try errContainer.decode(Int.self, forKey: .code)
                let message = try errContainer.decode(String.self, forKey: .message)
                self = .error(id: id, code: code, message: message)
            } else {
                let result = try container.decode(JSONRPCValue.self, forKey: .result)
                self = .response(id: id, result: result)
            }
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "Invalid JSON-RPC message"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        switch self {
        case .request(let id, let method, let params):
            try container.encode(id, forKey: .id)
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        case .response(let id, let result):
            try container.encode(id, forKey: .id)
            try container.encode(result, forKey: .result)
        case .error(let id, let code, let message):
            try container.encodeIfPresent(id, forKey: .id)
            var errContainer = container.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
            try errContainer.encode(code, forKey: .code)
            try errContainer.encode(message, forKey: .message)
        case .notification(let method, let params):
            try container.encode(method, forKey: .method)
            try container.encodeIfPresent(params, forKey: .params)
        }
    }
}

struct MCPToolError: Error {
    let message: String
}
```

- [ ] **Step 2: Write ToolRegistry.swift**

```swift
import Foundation
import SakuraWallpaperCore

struct MCPToolDefinition {
    let name: String
    let description: String
    let inputSchema: [String: JSONRPCValue]

    var json: JSONRPCValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .object(inputSchema)
        ])
    }
}

final class ToolRegistry {
    private var handlers: [String: ([String: JSONRPCValue]) throws -> JSONRPCValue] = [:]

    var toolDefinitions: [MCPToolDefinition] = []

    func register(_ definition: MCPToolDefinition, handler: @escaping ([String: JSONRPCValue]) throws -> JSONRPCValue) {
        toolDefinitions.append(definition)
        handlers[definition.name] = handler
    }

    func invoke(name: String, arguments: [String: JSONRPCValue]) throws -> JSONRPCValue {
        guard let handler = handlers[name] else {
            throw MCPToolError(message: "Unknown tool: \(name)")
        }
        return try handler(arguments)
    }

    func registerAll(wallpaperManager: WallpaperManager) {
        ListScreensTool.register(in: self)
        GetStatusTool.register(in: self, wallpaperManager: wallpaperManager)
        SetWallpaperTool.register(in: self, wallpaperManager: wallpaperManager)
        SetFolderTool.register(in: self, wallpaperManager: wallpaperManager)
        StopWallpaperTool.register(in: self, wallpaperManager: wallpaperManager)
        PauseResumeTool.register(in: self, wallpaperManager: wallpaperManager)
        NextWallpaperTool.register(in: self, wallpaperManager: wallpaperManager)
        GetSettingsTool.register(in: self)
        UpdateSettingsTool.register(in: self, wallpaperManager: wallpaperManager)
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
swift build --target sakura-mcp 2>&1
```

Expected: error about missing tool files — that's OK, we'll create them next.

- [ ] **Step 4: Commit**

```bash
git add Sources/sakura-mcp/MCPServer.swift Sources/sakura-mcp/ToolRegistry.swift
git commit -m "feat(mcp): implement JSON-RPC stdio transport and tool registry"
```

---

### Task 5: Implement list_screens Tool

**Files:**
- Create: `Sources/sakura-mcp/Tools/ListScreensTool.swift`

- [ ] **Step 1: Write ListScreensTool.swift**

```swift
import Cocoa
import SakuraWallpaperCore

enum ListScreensTool {
    static func register(in registry: ToolRegistry) {
        registry.register(MCPToolDefinition(
            name: "list_screens",
            description: "List all connected displays with their identifiers, names, and resolutions.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]
        )) { _ in
            let screens = NSScreen.screens.map { screen -> [String: JSONRPCValue] in
                let id = SettingsManager.screenIdentifier(screen)
                let frame = screen.frame
                return [
                    "id": .string(id),
                    "name": .string(screen.localizedName),
                    "x": .number(frame.origin.x),
                    "y": .number(frame.origin.y),
                    "width": .number(frame.size.width),
                    "height": .number(frame.size.height)
                ]
            }
            return .object(["screens": .array(screens)])
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build --target sakura-mcp 2>&1
```

Expected: errors about other missing tools. OK.

- [ ] **Step 3: Commit**

```bash
git add Sources/sakura-mcp/Tools/ListScreensTool.swift
git commit -m "feat(mcp): implement list_screens tool"
```

---

### Task 6: Implement get_status Tool

**Files:**
- Create: `Sources/sakura-mcp/Tools/GetStatusTool.swift`

- [ ] **Step 1: Write GetStatusTool.swift**

```swift
import Cocoa
import SakuraWallpaperCore

enum GetStatusTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager) {
        registry.register(MCPToolDefinition(
            name: "get_status",
            description: "Get current wallpaper playback status for all screens or a specific one.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "screen_id": .object([
                        "type": .string("string"),
                        "description": .string("Screen ID from list_screens. Omit for all screens.")
                    ])
                ]),
                "required": .array([])
            ]
        )) { args in
            let targetID = args["screen_id"]?.stringValue
            let screens = NSScreen.screens

            var result: [[String: JSONRPCValue]] = []
            for screen in screens {
                let id = SettingsManager.screenIdentifier(screen)
                if let t = targetID, t != id { continue }

                let config = SettingsManager.shared.screenConfig(for: id)
                let isPlaying = wallpaperManager.currentFiles[id] != nil
                let currentPath = wallpaperManager.currentFiles[id]?.path

                var entry: [String: JSONRPCValue] = [
                    "id": .string(id),
                    "name": .string(screen.localizedName),
                    "is_playing": .bool(isPlaying),
                    "is_paused": .bool(wallpaperManager.isPaused),
                    "is_folder_mode": .bool(config.isFolderMode),
                    "rotation_interval_minutes": .number(Double(config.rotationIntervalMinutes)),
                    "shuffle": .bool(config.isShuffleMode),
                    "include_subfolders": .bool(config.includeSubfolders),
                    "fit_mode": .string(config.wallpaperFit.rawValue)
                ]
                if let p = currentPath { entry["current_file"] = .string(p) }
                if let fp = config.folderPath { entry["folder_path"] = .string(fp) }
                if let wp = config.wallpaperPath { entry["wallpaper_path"] = .string(wp) }
                result.append(entry)
            }

            return .object(["screens": .array(result)])
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/sakura-mcp/Tools/GetStatusTool.swift
git commit -m "feat(mcp): implement get_status tool"
```

---

### Task 7: Implement set_wallpaper Tool

**Files:**
- Create: `Sources/sakura-mcp/Tools/SetWallpaperTool.swift`

- [ ] **Step 1: Write SetWallpaperTool.swift**

```swift
import Cocoa
import SakuraWallpaperCore

enum SetWallpaperTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager) {
        registry.register(MCPToolDefinition(
            name: "set_wallpaper",
            description: "Set a single image or video file as wallpaper on one or all screens.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "file_path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to the image or video file.")
                    ]),
                    "screen_id": .object([
                        "type": .string("string"),
                        "description": .string("Screen ID from list_screens. Omit for all screens.")
                    ])
                ]),
                "required": .array([.string("file_path")])
            ]
        )) { args in
            guard let filePath = args["file_path"]?.stringValue,
                  !filePath.isEmpty else {
                throw MCPToolError(message: "file_path is required and must be non-empty")
            }

            let url = URL(fileURLWithPath: filePath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: filePath, isDirectory: &isDir) else {
                throw MCPToolError(message: "File not found: \(filePath)")
            }
            guard !isDir.boolValue else {
                throw MCPToolError(message: "Path is a directory, not a file. Use set_folder for folders.")
            }

            let mediaType = MediaType.detect(url)
            guard mediaType != .unsupported else {
                throw MCPToolError(message: "Unsupported file format. Supported: mp4, mov, gif, m4v, png, jpg, jpeg, heic, webp, bmp, tiff")
            }

            let targetID = args["screen_id"]?.stringValue
            let screens = NSScreen.screens

            if let t = targetID {
                guard let screen = screens.first(where: { SettingsManager.screenIdentifier($0) == t }) else {
                    throw MCPToolError(message: "Screen not found: \(t)")
                }
                wallpaperManager.setWallpaper(url: url, for: screen)
            } else {
                for screen in screens {
                    wallpaperManager.setWallpaper(url: url, for: screen)
                }
            }

            return .object([
                "success": .bool(true),
                "file_path": .string(filePath)
            ])
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/sakura-mcp/Tools/SetWallpaperTool.swift
git commit -m "feat(mcp): implement set_wallpaper tool"
```

---

### Task 8: Implement set_folder Tool

**Files:**
- Create: `Sources/sakura-mcp/Tools/SetFolderTool.swift`

- [ ] **Step 1: Write SetFolderTool.swift**

```swift
import Cocoa
import SakuraWallpaperCore

enum SetFolderTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager) {
        registry.register(MCPToolDefinition(
            name: "set_folder",
            description: "Set a folder for wallpaper rotation on one or all screens.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "folder_path": .object([
                        "type": .string("string"),
                        "description": .string("Absolute path to a folder containing images/videos.")
                    ]),
                    "screen_id": .object([
                        "type": .string("string"),
                        "description": .string("Screen ID from list_screens. Omit for all screens.")
                    ]),
                    "rotation_interval_minutes": .object([
                        "type": .string("number"),
                        "description": .string("Minutes between wallpaper changes (default: 15).")
                    ]),
                    "shuffle": .object([
                        "type": .string("boolean"),
                        "description": .string("Randomize playback order.")
                    ]),
                    "include_subfolders": .object([
                        "type": .string("boolean"),
                        "description": .string("Include files from subdirectories.")
                    ]),
                    "fit_mode": .object([
                        "type": .string("string"),
                        "description": .string("Wallpaper fit mode: fill, fit, or stretch.")
                    ])
                ]),
                "required": .array([.string("folder_path")])
            ]
        )) { args in
            guard let folderPath = args["folder_path"]?.stringValue,
                  !folderPath.isEmpty else {
                throw MCPToolError(message: "folder_path is required")
            }

            let folderURL = URL(fileURLWithPath: folderPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir),
                  isDir.boolValue else {
                throw MCPToolError(message: "Folder not found or not a directory: \(folderPath)")
            }

            let targetID = args["screen_id"]?.stringValue
            let screens = NSScreen.screens

            let interval = args["rotation_interval_minutes"]?.numberValue
                .map { max(1, Int($0)) } ?? 15
            let shuffle = args["shuffle"]?.boolValue ?? false
            let includeSub = args["include_subfolders"]?.boolValue ?? false
            let fitRaw = args["fit_mode"]?.stringValue
            let fitMode: WallpaperFitMode = fitRaw.flatMap(WallpaperFitMode.init) ?? .fill
            let synced = screens.count > 1

            func makeConfig() -> Screen_Config {
                Screen_Config(
                    folderPath: folderPath,
                    wallpaperPath: nil,
                    rotationIntervalMinutes: interval,
                    isShuffleMode: shuffle,
                    isRotationEnabled: true,
                    includeSubfolders: includeSub,
                    isFolderMode: true,
                    isSynced: synced,
                    wallpaperFit: fitMode
                )
            }

            let config = makeConfig()

            if let t = targetID {
                guard let screen = screens.first(where: { SettingsManager.screenIdentifier($0) == t }) else {
                    throw MCPToolError(message: "Screen not found: \(t)")
                }
                wallpaperManager.setFolder(url: folderURL, for: screen, config: config)
            } else {
                for screen in screens {
                    wallpaperManager.setFolder(url: folderURL, for: screen, config: config)
                }
            }

            // Count files
            let fileCount = (try? PlaylistBuilder.collectMediaFiles(in: folderURL, includeSubfolders: includeSub).count) ?? 0

            return .object([
                "success": .bool(true),
                "folder_path": .string(folderPath),
                "file_count": .number(Double(fileCount))
            ])
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/sakura-mcp/Tools/SetFolderTool.swift
git commit -m "feat(mcp): implement set_folder tool"
```

---

### Task 9: Implement stop_wallpaper Tool

**Files:**
- Create: `Sources/sakura-mcp/Tools/StopWallpaperTool.swift`

- [ ] **Step 1: Write StopWallpaperTool.swift**

```swift
import Cocoa
import SakuraWallpaperCore

enum StopWallpaperTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager) {
        registry.register(MCPToolDefinition(
            name: "stop_wallpaper",
            description: "Stop wallpaper playback on one or all screens.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "screen_id": .object([
                        "type": .string("string"),
                        "description": .string("Screen ID from list_screens. Omit to stop all.")
                    ])
                ]),
                "required": .array([])
            ]
        )) { args in
            let targetID = args["screen_id"]?.stringValue
            let screens = NSScreen.screens

            var stopped: [String] = []
            if let t = targetID {
                guard let screen = screens.first(where: { SettingsManager.screenIdentifier($0) == t }) else {
                    throw MCPToolError(message: "Screen not found: \(t)")
                }
                wallpaperManager.stopWallpaper(for: screen)
                stopped = [t]
            } else {
                wallpaperManager.stopAll()
                stopped = screens.map { SettingsManager.screenIdentifier($0) }
            }

            return .object([
                "success": .bool(true),
                "stopped_screens": .array(stopped.map { .string($0) })
            ])
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/sakura-mcp/Tools/StopWallpaperTool.swift
git commit -m "feat(mcp): implement stop_wallpaper tool"
```

---

### Task 10: Implement pause_resume Tool

**Files:**
- Create: `Sources/sakura-mcp/Tools/PauseResumeTool.swift`

- [ ] **Step 1: Write PauseResumeTool.swift**

```swift
import SakuraWallpaperCore

enum PauseResumeTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager) {
        registry.register(MCPToolDefinition(
            name: "pause_resume",
            description: "Pause or resume wallpaper playback. When paused, videos freeze and rotation stops.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "action": .object([
                        "type": .string("string"),
                        "description": .string("'pause', 'resume', or 'toggle'.")
                    ])
                ]),
                "required": .array([.string("action")])
            ]
        )) { args in
            guard let action = args["action"]?.stringValue else {
                throw MCPToolError(message: "action is required: 'pause', 'resume', or 'toggle'")
            }

            switch action {
            case "pause":
                wallpaperManager.isPaused = true
                wallpaperManager.checkPlaybackState()
            case "resume":
                wallpaperManager.isPaused = false
                wallpaperManager.checkPlaybackState()
            case "toggle":
                wallpaperManager.isPaused.toggle()
                wallpaperManager.checkPlaybackState()
            default:
                throw MCPToolError(message: "Invalid action: '\(action)'. Use 'pause', 'resume', or 'toggle'.")
            }

            return .object([
                "paused": .bool(wallpaperManager.isPaused)
            ])
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/sakura-mcp/Tools/PauseResumeTool.swift
git commit -m "feat(mcp): implement pause_resume tool"
```

---

### Task 11: Implement next_wallpaper Tool

**Files:**
- Create: `Sources/sakura-mcp/Tools/NextWallpaperTool.swift`

- [ ] **Step 1: Write NextWallpaperTool.swift**

```swift
import Cocoa
import SakuraWallpaperCore

enum NextWallpaperTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager) {
        registry.register(MCPToolDefinition(
            name: "next_wallpaper",
            description: "Skip to the next wallpaper in the rotation for one or all screens.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "screen_id": .object([
                        "type": .string("string"),
                        "description": .string("Screen ID from list_screens. Omit for all screens.")
                    ])
                ]),
                "required": .array([])
            ]
        )) { args in
            let targetID = args["screen_id"]?.stringValue
            let screens = NSScreen.screens

            var results: [[String: JSONRPCValue]] = []
            if let t = targetID {
                guard let screen = screens.first(where: { SettingsManager.screenIdentifier($0) == t }) else {
                    throw MCPToolError(message: "Screen not found: \(t)")
                }
                wallpaperManager.nextWallpaper(for: screen)
                let newFile = wallpaperManager.currentFiles[t]?.path ?? ""
                results.append(["id": .string(t), "new_file": .string(newFile)])
            } else {
                wallpaperManager.nextWallpaper()
                for screen in screens {
                    let id = SettingsManager.screenIdentifier(screen)
                    let newFile = wallpaperManager.currentFiles[id]?.path ?? ""
                    results.append(["id": .string(id), "new_file": .string(newFile)])
                }
            }

            return .object([
                "success": .bool(true),
                "results": .array(results)
            ])
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/sakura-mcp/Tools/NextWallpaperTool.swift
git commit -m "feat(mcp): implement next_wallpaper tool"
```

---

### Task 12: Implement get_settings Tool

**Files:**
- Create: `Sources/sakura-mcp/Tools/GetSettingsTool.swift`

- [ ] **Step 1: Write GetSettingsTool.swift**

```swift
import Cocoa
import SakuraWallpaperCore

enum GetSettingsTool {
    static func register(in registry: ToolRegistry) {
        registry.register(MCPToolDefinition(
            name: "get_settings",
            description: "Read current wallpaper configuration for one or all screens.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "screen_id": .object([
                        "type": .string("string"),
                        "description": .string("Screen ID from list_screens. Omit for all screens.")
                    ])
                ]),
                "required": .array([])
            ]
        )) { args in
            let targetID = args["screen_id"]?.stringValue
            let screens = NSScreen.screens

            var result: [[String: JSONRPCValue]] = []
            for screen in screens {
                let id = SettingsManager.screenIdentifier(screen)
                if let t = targetID, t != id { continue }

                let config = SettingsManager.shared.screenConfig(for: id)
                var entry: [String: JSONRPCValue] = [
                    "id": .string(id),
                    "name": .string(screen.localizedName),
                    "rotation_interval_minutes": .number(Double(config.rotationIntervalMinutes)),
                    "shuffle": .bool(config.isShuffleMode),
                    "rotation_enabled": .bool(config.isRotationEnabled),
                    "include_subfolders": .bool(config.includeSubfolders),
                    "is_folder_mode": .bool(config.isFolderMode),
                    "is_synced": .bool(config.isSynced),
                    "fit_mode": .string(config.wallpaperFit.rawValue)
                ]
                if let fp = config.folderPath { entry["folder_path"] = .string(fp) }
                if let wp = config.wallpaperPath { entry["wallpaper_path"] = .string(wp) }
                result.append(entry)
            }

            return .object(["screens": .array(result)])
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/sakura-mcp/Tools/GetSettingsTool.swift
git commit -m "feat(mcp): implement get_settings tool"
```

---

### Task 13: Implement update_settings Tool

**Files:**
- Create: `Sources/sakura-mcp/Tools/UpdateSettingsTool.swift`

- [ ] **Step 1: Write UpdateSettingsTool.swift**

```swift
import Cocoa
import SakuraWallpaperCore

enum UpdateSettingsTool {
    static func register(in registry: ToolRegistry, wallpaperManager: WallpaperManager) {
        registry.register(MCPToolDefinition(
            name: "update_settings",
            description: "Update wallpaper configuration parameters without changing the current wallpaper.",
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "screen_id": .object([
                        "type": .string("string"),
                        "description": .string("Screen ID. Omit for all screens.")
                    ]),
                    "rotation_interval_minutes": .object([
                        "type": .string("number"),
                        "description": .string("Minutes between wallpaper changes.")
                    ]),
                    "shuffle": .object([
                        "type": .string("boolean"),
                        "description": .string("Enable or disable shuffle.")
                    ]),
                    "rotation_enabled": .object([
                        "type": .string("boolean"),
                        "description": .string("Enable or disable wallpaper rotation.")
                    ]),
                    "include_subfolders": .object([
                        "type": .string("boolean"),
                        "description": .string("Include files from subdirectories.")
                    ]),
                    "fit_mode": .object([
                        "type": .string("string"),
                        "description": .string("fill, fit, or stretch.")
                    ]),
                    "is_synced": .object([
                        "type": .string("boolean"),
                        "description": .string("Sync settings across screens.")
                    ])
                ]),
                "required": .array([])
            ]
        )) { args in
            let targetID = args["screen_id"]?.stringValue
            let screens = NSScreen.screens
            var updatedFields: [String] = []

            func apply(to id: String) {
                var config = SettingsManager.shared.screenConfig(for: id)

                if let v = args["rotation_interval_minutes"]?.numberValue {
                    config.rotationIntervalMinutes = max(1, Int(v))
                    updatedFields.append("rotation_interval_minutes")
                }
                if let v = args["shuffle"]?.boolValue {
                    config.isShuffleMode = v
                    updatedFields.append("shuffle")
                }
                if let v = args["rotation_enabled"]?.boolValue {
                    config.isRotationEnabled = v
                    updatedFields.append("rotation_enabled")
                }
                if let v = args["include_subfolders"]?.boolValue {
                    config.includeSubfolders = v
                    updatedFields.append("include_subfolders")
                    // Rebuild playlist if folder is set
                    if let fp = config.folderPath {
                        wallpaperManager.setFolder(url: URL(fileURLWithPath: fp), for: NSScreen.screens.first(where: { SettingsManager.screenIdentifier($0) == id })!, config: config)
                        return
                    }
                }
                if let v = args["fit_mode"]?.stringValue, let fit = WallpaperFitMode(rawValue: v) {
                    config.wallpaperFit = fit
                    updatedFields.append("fit_mode")
                }
                if let v = args["is_synced"]?.boolValue {
                    config.isSynced = v
                    updatedFields.append("is_synced")
                }

                SettingsManager.shared.setScreenConfig(config, for: id)
            }

            if let t = targetID {
                guard screens.contains(where: { SettingsManager.screenIdentifier($0) == t }) else {
                    throw MCPToolError(message: "Screen not found: \(t)")
                }
                apply(to: t)
            } else {
                for screen in screens {
                    apply(to: SettingsManager.screenIdentifier(screen))
                }
            }

            return .object([
                "success": .bool(true),
                "updated_fields": .array(updatedFields.map { .string($0) })
            ])
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/sakura-mcp/Tools/UpdateSettingsTool.swift
git commit -m "feat(mcp): implement update_settings tool"
```

---

### Task 14: Implement IPC Sync (DistributedNotificationCenter)

**Files:**
- Create: `Sources/sakura-mcp/IPCSync.swift`
- Modify: `Sources/sakura-mcp/main.swift`

- [ ] **Step 1: Write IPCSync.swift**

```swift
import Foundation

enum IPCSync {
    private static let center = DistributedNotificationCenter.default()
    private static let stateChangedName = "SakuraWallpaperStateChanged"

    /// Post a notification that state has changed (GUI app picks this up to refresh UI)
    static func notifyStateChanged(screenID: String? = nil, field: String? = nil) {
        var info: [String: String] = [:]
        if let id = screenID { info["screenID"] = id }
        if let f = field { info["field"] = f }
        center.postNotificationName(NSNotification.Name(stateChangedName),
                                     object: nil,
                                     userInfo: info.isEmpty ? nil : info,
                                     deliverImmediately: true)
    }

    /// Observe state changes from the GUI app
    static func observeStateChanges(handler: @escaping ([String: String]?) -> Void) {
        center.addObserver(forName: NSNotification.Name(stateChangedName),
                            object: nil,
                            queue: .main) { notification in
            handler(notification.userInfo as? [String: String])
        }
    }
}
```

- [ ] **Step 2: Update main.swift to initialize IPC observer**

Add after `server.run()` in `main.swift`:

```swift
IPCSync.observeStateChanges { userInfo in
    // GUI app made a change — our state is already synced via UserDefaults,
    // but we could log it or trigger additional behavior here.
    // For now: no-op. UserDefaults is the source of truth.
}
```

- [ ] **Step 3: Add `.notifyStateChanged()` calls to each tool**

After each operation that mutates state (in `SetWallpaperTool`, `SetFolderTool`, `StopWallpaperTool`, `PauseResumeTool`, `NextWallpaperTool`, `UpdateSettingsTool`), add:

```swift
IPCSync.notifyStateChanged(screenID: targetID)
```

- [ ] **Step 4: Commit**

```bash
git add Sources/sakura-mcp/IPCSync.swift Sources/sakura-mcp/main.swift
git add Sources/sakura-mcp/Tools/*.swift
git commit -m "feat(mcp): add DistributedNotificationCenter IPC sync between CLI and GUI"
```

---

### Task 15: Fix Compilation and Add Claude Desktop Config

**Files:**
- Modify: various (fixes after build)
- Create: `docs/mcp-config.json`

- [ ] **Step 1: Full build**

```bash
swift build --target sakura-mcp 2>&1
```

Expected: `Build complete!` — fix any compilation errors. Common issues:
- `numberValue` / `boolValue` accessors missing on `JSONRPCValue` — add them if needed
- `rotate(for:)` not found on WallpaperManager — implement or use alternative
- Import missing for `NSScreen` / `Cocoa` in tool files

- [ ] **Step 2: Create Claude Desktop config template**

`docs/mcp-config.json`:
```json
{
  "mcpServers": {
    "sakura-wallpaper": {
      "command": "swift",
      "args": ["run", "--package-path", "/absolute/path/to/SakuraWallpaper", "sakura-mcp"]
    }
  }
}
```

- [ ] **Step 3: Manual smoke test**

```bash
echo '{"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' | swift run --package-path . sakura-mcp 2>/dev/null
```

Expected: JSON-RPC response with `protocolVersion`, `capabilities`, `serverInfo`.

- [ ] **Step 4: Test tools/list**

```bash
echo '{"jsonrpc":"2.0","id":"2","method":"tools/list","params":{}}' | swift run --package-path . sakura-mcp 2>/dev/null
```

Expected: JSON array of 9 tool definitions.

- [ ] **Step 5: Commit**

```bash
git add docs/mcp-config.json
git commit -m "docs: add Claude Desktop MCP config template"
```

---

### Task 16: Integration Tests

**Files:**
- Create: `Tests/sakura-mcpTests/MCPServerTests.swift`

- [ ] **Step 1: Write test for JSON-RPC initialize handshake**

```swift
import XCTest
@testable import sakura_mcp

final class MCPServerTests: XCTestCase {
    func testInitialize() throws {
        // JSON-RPC initialize request
        let request = """
        {"jsonrpc":"2.0","id":"1","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}
        """

        let data = request.data(using: .utf8)!
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: data)

        guard case .request(let id, let method, _) = message else {
            XCTFail("Expected request")
            return
        }
        XCTAssertEqual(id, "1")
        XCTAssertEqual(method, "initialize")
    }

    func testToolsList() throws {
        let request = """
        {"jsonrpc":"2.0","id":"2","method":"tools/list","params":{}}
        """

        let data = request.data(using: .utf8)!
        let message = try JSONDecoder().decode(JSONRPCMessage.self, from: data)

        guard case .request(let id, let method, _) = message else {
            XCTFail("Expected request")
            return
        }
        XCTAssertEqual(id, "2")
        XCTAssertEqual(method, "tools/list")
    }

    func testJSONRPCValueRoundtrip() throws {
        let original: JSONRPCValue = .object([
            "name": .string("test"),
            "count": .number(42),
            "active": .bool(true),
            "items": .array([.string("a"), .string("b")])
        ])

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONRPCValue.self, from: encoded)

        XCTAssertEqual(original, decoded)
    }
}
```

- [ ] **Step 2: Run tests**

```bash
swift test --filter MCPServerTests 2>&1
```

Expected: All 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/sakura-mcpTests/
git commit -m "test(mcp): add JSON-RPC serialization tests"
```

---

### Task 17: Final Verification

- [ ] **Step 1: Full build + test**

```bash
swift build 2>&1 && swift test 2>&1
```

Expected: `Build complete!` + all tests pass.

- [ ] **Step 2: Verify build.sh still works (GUI app unchanged)**

```bash
bash build.sh 2>&1
```

Expected: Compiles and signs successfully, produces universal binary.

- [ ] **Step 3: Push**

```bash
git push origin main
```
