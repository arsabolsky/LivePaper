import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var statusMenuItem: NSMenuItem!
    var mainWindow: MainWindowController!
    var wallpaperManager: WallpaperManager!
    var recentMenu: NSMenu!
    var aboutWindow: AboutWindowController?
    var pauseItem: NSMenuItem!
    var pauseMenu: NSMenu!
    var pauseAllItem: NSMenuItem!
    var batteryPauseItem: NSMenuItem!
    var batteryPauseMenu: NSMenu!
    var visibilityPauseItem: NSMenuItem!
    var visibilityPauseMenu: NSMenu!
    var nextMenuItem: NSMenuItem!
    var nextWallpaperMenu: NSMenu!
    var languageMenu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        wallpaperManager = WallpaperManager()
        SettingsManager.shared.migratePausePoliciesIfNeeded()
        mainWindow = MainWindowController(wallpaperManager: wallpaperManager)
        setupStatusBar()

        SettingsManager.shared.runCleanSlateInitIfNeeded()
        wallpaperManager.restoreAllScreens()
        mainWindow.runOnboardingIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        wallpaperManager.stopAll()
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖼️"

        let menu = NSMenu()

        let openItem = NSMenuItem(title: "menu.open".localized, action: #selector(openMain), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        statusMenuItem = NSMenuItem(title: "menu.status".localized("ui.notSet".localized), action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        pauseMenu = NSMenu(title: "menu.pause".localized)
        pauseItem = NSMenuItem(title: "menu.pause".localized, action: nil, keyEquivalent: "")
        pauseItem.submenu = pauseMenu
        menu.addItem(pauseItem)

        nextWallpaperMenu = NSMenu(title: "menu.nextWallpaper".localized)
        nextMenuItem = NSMenuItem(title: "menu.nextWallpaper".localized, action: nil, keyEquivalent: "")
        nextMenuItem.submenu = nextWallpaperMenu
        menu.addItem(nextMenuItem)

        let stopItem = NSMenuItem(title: "menu.stopWallpaper".localized, action: #selector(stopWallpaper), keyEquivalent: "s")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(.separator())

        batteryPauseMenu = NSMenu(title: "menu.batteryPause".localized)
        batteryPauseItem = NSMenuItem(title: "menu.batteryPause".localized, action: nil, keyEquivalent: "")
        batteryPauseItem.submenu = batteryPauseMenu
        menu.addItem(batteryPauseItem)

        visibilityPauseMenu = NSMenu(title: "menu.visibilityPause".localized)
        visibilityPauseItem = NSMenuItem(title: "menu.visibilityPause".localized, action: nil, keyEquivalent: "")
        visibilityPauseItem.submenu = visibilityPauseMenu
        menu.addItem(visibilityPauseItem)

        languageMenu = NSMenu(title: "menu.language".localized)
        let languageItem = NSMenuItem(title: "menu.language".localized, action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(.separator())

        recentMenu = NSMenu(title: "menu.recent".localized)
        let recentItem = NSMenuItem(title: "menu.recent".localized, action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        let clearItem = NSMenuItem(title: "menu.clearHistory".localized, action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "menu.about".localized, action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "menu.quit".localized, action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        menu.delegate = self
        rebuildRecentMenu()
    }

    func rebuildRecentMenu() {
        recentMenu.removeAllItems()
        let history = SettingsManager.shared.wallpaperHistory
        if history.isEmpty {
            let empty = NSMenuItem(title: "menu.empty".localized, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentMenu.addItem(empty)
            return
        }
        for path in history {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let filename = (path as NSString).lastPathComponent
            let item = NSMenuItem(title: filename, action: #selector(switchToRecent(_:)), keyEquivalent: "")
            item.representedObject = path
            item.target = self

            // Check if this path is currently active on any screen
            let isActive = NSScreen.screens.contains { screen in
                let id = SettingsManager.screenIdentifier(screen)
                let config = SettingsManager.shared.screenConfig(for: id)
                return config.folderPath == path || config.wallpaperPath == path
            }
            item.state = isActive ? .on : .off

            let icon = iconFor(path: path)
            item.image = icon
            requestAsyncIcon(for: path, item: item)

            recentMenu.addItem(item)
        }
    }

    private func iconFor(path: String) -> NSImage? {
        return NSWorkspace.shared.icon(forFile: path)
    }

    private func requestAsyncIcon(for path: String, item: NSMenuItem) {
        let url = URL(fileURLWithPath: path)
        ThumbnailProvider.shared.requestThumbnail(for: url, size: NSSize(width: 20, height: 20)) { [weak item] image in
            guard let item else { return }
            guard let image else { return }
            item.image = image
        }
    }

    @objc func switchToRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        let url = URL(fileURLWithPath: path)
        
        // Track which screens we've already handled via sync group propagation
        var handledScreenIDs = Set<String>()
        
        for screen in NSScreen.screens {
            let id = SettingsManager.screenIdentifier(screen)
            if handledScreenIDs.contains(id) { continue }
            
            if isDir.boolValue {
                var config = SettingsManager.shared.screenConfig(for: id)
                config.folderPath = url.path
                config.isFolderMode = true
                wallpaperManager.setFolder(url: url, for: screen, config: config)
            } else {
                wallpaperManager.setWallpaper(url: url, for: screen)
            }
            
            // Mark this screen and all its synced peers as handled
            handledScreenIDs.insert(id)
            let config = SettingsManager.shared.screenConfig(for: id)
            if config.isSynced {
                for otherScreen in NSScreen.screens {
                    let otherId = SettingsManager.screenIdentifier(otherScreen)
                    if SettingsManager.shared.screenConfig(for: otherId).isSynced {
                        handledScreenIDs.insert(otherId)
                    }
                }
            }
        }
        
        mainWindow.updateUI()
        rebuildRecentMenu()
    }

    @objc func clearHistory() {
        SettingsManager.shared.wallpaperHistory = []
        rebuildRecentMenu()
    }

    private func rebuildNextWallpaperMenu() {
        nextWallpaperMenu.removeAllItems()

        let allItem = NSMenuItem(title: "ui.allScreens".localized, action: #selector(nextWallpaperAllScreens), keyEquivalent: "n")
        allItem.target = self
        allItem.isEnabled = wallpaperManager.hasAnyNextWallpaperTarget
        nextWallpaperMenu.addItem(allItem)
        nextWallpaperMenu.addItem(.separator())

        for (index, screen) in NSScreen.screens.enumerated() {
            let displayName: String
            if #available(macOS 10.15, *) {
                displayName = screen.localizedName
            } else {
                displayName = "screen.display".localized(index + 1)
            }
            let item = NSMenuItem(title: displayName, action: #selector(nextWallpaperForScreen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = screen
            item.isEnabled = wallpaperManager.canGoNextWallpaper(for: screen)
            nextWallpaperMenu.addItem(item)
        }
    }

    private func rebuildLanguageMenu() {
        languageMenu.removeAllItems()
        let currentLanguage = SettingsManager.shared.language
        
        let languages = [
            ("system", "language.system".localized),
            ("en", "language.en".localized),
            ("zh-Hans", "language.zh-Hans".localized)
        ]
        
        for (code, name) in languages {
            let item = NSMenuItem(title: name, action: #selector(switchLanguage(_:)), keyEquivalent: "")
            item.representedObject = code
            item.target = self
            item.state = (code == currentLanguage) ? .on : .off
            languageMenu.addItem(item)
        }
    }

    @objc func switchLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        SettingsManager.shared.language = code
        rebuildLanguageMenu()
        
        let alert = NSAlert()
        alert.messageText = "menu.language".localized
        alert.informativeText = "language.restartHint".localized
        alert.alertStyle = .informational
        alert.addButton(withTitle: "alert.ok".localized)
        alert.runModal()
    }

    @objc func openMain() {
        mainWindow.updateUI()
        mainWindow.showWindow(nil)
        mainWindow.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func stopWallpaper() {
        wallpaperManager.stopAll()
        for screen in NSScreen.screens {
            let id = SettingsManager.screenIdentifier(screen)
            SettingsManager.shared.setScreenConfig(Screen_Config.default, for: id)
        }
        mainWindow.updateUI()
        rebuildRecentMenu()
    }

    @objc func togglePauseAllFromMenu() {
        if wallpaperManager.isPaused {
            wallpaperManager.resume()
        } else {
            wallpaperManager.pause()
        }
        updatePauseItem()
        mainWindow.updateUI()
    }

    @objc func togglePauseForScreen(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        if wallpaperManager.isScreenPaused(screen) {
            wallpaperManager.resumeScreen(screen)
        } else {
            wallpaperManager.pauseScreen(screen)
        }
        mainWindow.updateUI()
    }

    private func rebuildBatteryPauseMenu() {
        batteryPauseMenu.removeAllItems()
        let current = SettingsManager.shared.batteryPausePolicy
        let options: [(BatteryPausePolicy, String)] = [
            (.off, "policy.battery.off".localized),
            (.lowBattery, "policy.battery.lowBattery".localized),
            (.onBattery, "policy.battery.onBattery".localized),
            (.followLowPowerMode, "policy.battery.followLowPowerMode".localized),
        ]
        for (policy, title) in options {
            let item = NSMenuItem(title: title, action: #selector(setBatteryPolicy(_:)), keyEquivalent: "")
            item.representedObject = policy.rawValue
            item.target = self
            item.state = (policy == current) ? .on : .off
            batteryPauseMenu.addItem(item)
        }
    }

    private func rebuildVisibilityPauseMenu() {
        visibilityPauseMenu.removeAllItems()
        let current = SettingsManager.shared.visibilityPausePolicy
        let options: [(VisibilityPausePolicy, String)] = [
            (.off, "policy.visibility.off".localized),
            (.covered, "policy.visibility.covered".localized),
            (.unfocused, "policy.visibility.unfocused".localized),
        ]
        for (policy, title) in options {
            let item = NSMenuItem(title: title, action: #selector(setVisibilityPolicy(_:)), keyEquivalent: "")
            item.representedObject = policy.rawValue
            item.target = self
            item.state = (policy == current) ? .on : .off
            visibilityPauseMenu.addItem(item)
        }
    }

    @objc func setBatteryPolicy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let policy = BatteryPausePolicy(rawValue: raw) else { return }
        SettingsManager.shared.batteryPausePolicy = policy
        wallpaperManager.onPausePolicyChanged()
        rebuildBatteryPauseMenu()
        mainWindow.updateUI()
    }

    @objc func setVisibilityPolicy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let policy = VisibilityPausePolicy(rawValue: raw) else { return }
        SettingsManager.shared.visibilityPausePolicy = policy
        wallpaperManager.onPausePolicyChanged()
        rebuildVisibilityPauseMenu()
        mainWindow.updateUI()
    }

    private func rebuildPauseMenu() {
        pauseMenu.removeAllItems()

        let allSuffix = wallpaperManager.isPaused ? " - \("menu.resume".localized)" : " - \("menu.pause".localized)"
        pauseAllItem = NSMenuItem(title: "\("ui.allScreens".localized)\(allSuffix)", action: #selector(togglePauseAllFromMenu), keyEquivalent: "p")
        pauseAllItem.target = self
        pauseAllItem.state = wallpaperManager.isPaused ? .on : .off
        pauseAllItem.isEnabled = wallpaperManager.isActive
        pauseMenu.addItem(pauseAllItem)
        pauseMenu.addItem(.separator())

        for (index, screen) in NSScreen.screens.enumerated() {
            let displayName: String
            if #available(macOS 10.15, *) {
                displayName = screen.localizedName
            } else {
                displayName = "screen.display".localized(index + 1)
            }
            let reasons = wallpaperManager.reasons(for: screen)
            let isManuallyPaused = wallpaperManager.isScreenPaused(screen)
            let suffix: String
            if let dominant = reasons.max(by: { $0.statusPriority < $1.statusPriority }) {
                suffix = " — " + "reason.\(dominant.rawValue)".localized
            } else {
                suffix = " — " + "ui.playing".localized
            }
            let item = NSMenuItem(title: "\(displayName)\(suffix)", action: #selector(togglePauseForScreen(_:)), keyEquivalent: "")
            item.representedObject = screen
            item.target = self
            item.state = isManuallyPaused ? .on : .off
            item.isEnabled = wallpaperManager.isActive
            pauseMenu.addItem(item)
        }
    }

    private func updatePauseItem() {
        pauseItem.title = "menu.pause".localized
        pauseItem.isEnabled = wallpaperManager.isActive
    }

    private func updateStatusLine() {
        if !wallpaperManager.isActive {
            statusMenuItem.title = "menu.status".localized("ui.notSet".localized)
            return
        }
        let stateLabel: String
        switch wallpaperManager.statusSummary {
        case .stopped:          stateLabel = "ui.notSet".localized
        case .playing:          stateLabel = "ui.playing".localized
        case .partiallyPaused:  stateLabel = "status.partiallyPaused".localized
        case .paused(let reason):
            stateLabel = "reason.\(reason.rawValue)".localized
        }
        let firstActiveScreen = NSScreen.screens.first
        let firstID = firstActiveScreen.map { SettingsManager.screenIdentifier($0) } ?? ""
        let config = SettingsManager.shared.screenConfig(for: firstID)
        let isRotating = config.isFolderMode && config.isRotationEnabled
        let shuffleIcon = (isRotating && config.isShuffleMode) ? "🔀 " : ""
        if isRotating, let folderPath = config.folderPath {
            let folderName = (folderPath as NSString).lastPathComponent
            statusMenuItem.title = "\(shuffleIcon)\("menu.status.rotating".localized(folderName)) (\(stateLabel))"
        } else if let url = firstActiveScreen.flatMap({ wallpaperManager.currentFile(for: SettingsManager.screenIdentifier($0)) }) {
            statusMenuItem.title = "menu.status.file".localized(url.lastPathComponent) + " (\(stateLabel))"
        } else {
            statusMenuItem.title = "menu.status".localized(stateLabel)
        }
    }

    @objc func showAbout() {
        if aboutWindow == nil {
            aboutWindow = AboutWindowController()
        }
        aboutWindow?.showWindow(nil)
        aboutWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitApp() {
        wallpaperManager.stopAll()
        NSApp.terminate(nil)
    }

    @objc func nextWallpaperAllScreens() {
        wallpaperManager.nextWallpaper()
    }

    @objc func nextWallpaperForScreen(_ sender: NSMenuItem) {
        guard let screen = sender.representedObject as? NSScreen else { return }
        wallpaperManager.nextWallpaper(for: screen)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(nextWallpaperAllScreens) {
            return wallpaperManager.hasAnyNextWallpaperTarget
        }
        if menuItem.action == #selector(nextWallpaperForScreen(_:)) {
            if let screen = menuItem.representedObject as? NSScreen {
                return wallpaperManager.canGoNextWallpaper(for: screen)
            }
            return false
        }
        return true
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildRecentMenu()
        rebuildPauseMenu()
        rebuildNextWallpaperMenu()
        rebuildLanguageMenu()
        updatePauseItem()
        rebuildBatteryPauseMenu()
        rebuildVisibilityPauseMenu()
        updateStatusLine()
    }
}
