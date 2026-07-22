# Footprint Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut LivePaper's runtime footprint (idle CPU/energy, RAM, GPU-while-playing) via three no-feature-loss tunings: event-driven window ordering, a conditional FPS cap for high-fps sources, and timer coalescing.

**Architecture:** The one bug-prone decision (whether/where to cap frame rate) is extracted into a pure, unit-tested helper in the `LivePaperCore` package target. The rest is AppKit/AVFoundation wiring in `WallpaperManager` and `ScreenPlayer` (excluded from the test target), verified by build + a reproducible `top` measurement harness. No public API, settings, localization, or persisted data change.

**Tech Stack:** Swift 5.9, AppKit, AVFoundation; SwiftPM `LivePaperCore` + XCTest; app built via `./build.sh`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-22-footprint-optimization-design.md` — authoritative.
- **No feature removal or behavior change** visible to the user (these are internal tunings). Wallpaper must still play, rotate, sync, and obey every pause policy.
- **Deployment target macOS 12.0.** Compile under `-target arm64-apple-macos12.0`. `NSScreen.maximumFramesPerSecond` (12.0+) and `AVMutableVideoComposition(propertiesOf:)` / `loadValuesAsynchronously` (deprecated in 13 but available) are permitted; deprecation *warnings* are acceptable (build.sh does not use `-warnings-as-errors`).
- **FPS-cap gate (exact):** cap target = `min(screenMaxFPS, 60)` with `screenMaxFPS <= 0` falling back to 60; apply a composition **only if** `sourceFPS > target + 1`. Otherwise no composition (zero overhead).
- **Timer tolerances (exact):** rotation timers `tolerance = interval * 0.1`; battery poll interval `60s → 120s`, `tolerance = 15`; order-backstop timer `8s`, `tolerance = 2`.
- **No public API changes** to `WallpaperManager`. Internal renames only.
- **Access modifiers:** match existing files (default internal). Tests use `@testable import LivePaperCore`.
- **New pure files MUST be added to `Package.swift` `sources:` AND to `build.sh`'s swiftc list.**
- **Test runner:** `swift test` needs XCTest (full Xcode). On a Command-Line-Tools-only machine it fails with "unable to resolve module dependency: 'XCTest'"; the fallback for pure-logic verification is the whole-app typecheck (below). Still write the test files.
- **Whole-app typecheck** (`[TYPECHECK]`), expected exit 0, no output:
  ```bash
  swiftc -typecheck -target "$(uname -m)-apple-macos12.0" \
    Screen_Config.swift SettingsManager.swift MediaType.swift PlaylistBuilder.swift \
    Localization.swift PerformanceMonitor.swift ScreenPlayer.swift WallpaperManager.swift \
    MainWindowController.swift ThumbnailItem.swift ThumbnailProvider.swift \
    AboutWindowController.swift AppDelegate.swift main.swift \
    PausePolicy.swift PauseEvaluator.swift PauseCoordinator.swift PlaybackTuning.swift \
    -framework Cocoa -framework AVKit -framework AVFoundation \
    -framework ServiceManagement -framework ImageIO -framework IOKit
  ```
- **Branch:** `performance-tweaks`. Commit per task. Co-author trailer:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## File Structure

**New (add to `Package.swift` sources + `build.sh`):**
- `PlaybackTuning.swift` — pure `PlaybackTuning.frameRateCapTarget(sourceFPS:screenMaxFPS:) -> Int?`. Unit-tested.

**Modified:**
- `ScreenPlayer.swift` — apply the FPS-cap composition in `setupVideoPlayer` (§2 of spec).
- `WallpaperManager.swift` — rename `showAll()`→`reassertWindowOrder()`, call it in `reconcile()`, replace the 0.75s keep-visible timer with an 8s±2s backstop, add `.tolerance` to all repeating timers, and lengthen the battery poll (§1 and §3).

**Tests (new):**
- `Tests/LivePaperCoreTests/PlaybackTuningTests.swift`

---

## Task 1: Pure FPS-cap decision helper

**Files:**
- Create: `PlaybackTuning.swift`
- Modify: `Package.swift` (add source), `build.sh` (add source)
- Test: `Tests/LivePaperCoreTests/PlaybackTuningTests.swift`

**Interfaces:**
- Produces: `enum PlaybackTuning { static func frameRateCapTarget(sourceFPS: Float, screenMaxFPS: Int) -> Int? }`.

- [ ] **Step 1: Register the new file in Package.swift**

In `Package.swift`, change the `LivePaperCore` target's `sources:` array from ending:
```swift
                "PauseCoordinator.swift"
            ],
```
to:
```swift
                "PauseCoordinator.swift",
                "PlaybackTuning.swift"
            ],
```

- [ ] **Step 2: Register the new file in build.sh**

In `build.sh`, in the `swiftc` file list, add `PlaybackTuning.swift` after `PauseCoordinator.swift`:
```
    PausePolicy.swift \
    PauseEvaluator.swift \
    PauseCoordinator.swift \
    PlaybackTuning.swift \
    MainWindowController.swift \
```

- [ ] **Step 3: Write the failing test**

Create `Tests/LivePaperCoreTests/PlaybackTuningTests.swift`:
```swift
import XCTest
@testable import LivePaperCore

final class PlaybackTuningTests: XCTestCase {
    func testHighFpsClipCapsToDisplay() {
        XCTAssertEqual(PlaybackTuning.frameRateCapTarget(sourceFPS: 120, screenMaxFPS: 60), 60)
    }

    func testNormalFpsClipGetsNoCap() {
        XCTAssertNil(PlaybackTuning.frameRateCapTarget(sourceFPS: 60, screenMaxFPS: 60))
        XCTAssertNil(PlaybackTuning.frameRateCapTarget(sourceFPS: 30, screenMaxFPS: 60))
        XCTAssertNil(PlaybackTuning.frameRateCapTarget(sourceFPS: 23.976, screenMaxFPS: 60))
    }

    func testCapNeverExceeds60EvenOnProMotion() {
        // 120Hz ProMotion display, 120fps clip → still capped at 60.
        XCTAssertEqual(PlaybackTuning.frameRateCapTarget(sourceFPS: 120, screenMaxFPS: 120), 60)
        XCTAssertEqual(PlaybackTuning.frameRateCapTarget(sourceFPS: 240, screenMaxFPS: 120), 60)
    }

    func testUnknownRefreshFallsBackTo60() {
        XCTAssertEqual(PlaybackTuning.frameRateCapTarget(sourceFPS: 120, screenMaxFPS: 0), 60)
        XCTAssertNil(PlaybackTuning.frameRateCapTarget(sourceFPS: 60, screenMaxFPS: 0))
    }

    func testOneFpsGuardAvoidsPointlessCap() {
        // Just above target triggers; within 1fps does not.
        XCTAssertNil(PlaybackTuning.frameRateCapTarget(sourceFPS: 61, screenMaxFPS: 60))
        XCTAssertEqual(PlaybackTuning.frameRateCapTarget(sourceFPS: 62, screenMaxFPS: 60), 60)
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `swift test --filter PlaybackTuningTests`
Expected: FAIL — `cannot find 'PlaybackTuning' in scope`. (On a CLT-only box `swift test` errors on XCTest; then rely on `[TYPECHECK]` in Step 6.)

- [ ] **Step 5: Implement `PlaybackTuning.swift`**

Create `PlaybackTuning.swift`:
```swift
import Foundation

/// Pure playback-tuning decisions, isolated for testing.
enum PlaybackTuning {
    /// The frame rate to cap rendering at, or nil if no cap should be applied.
    ///
    /// Caps to `min(screenMaxFPS, 60)`, but only when the source exceeds that by
    /// more than 1 fps — so normal-rate clips (24/30/60) get no cap and therefore
    /// no video-composition overhead. `screenMaxFPS <= 0` (unknown refresh) falls
    /// back to 60.
    static func frameRateCapTarget(sourceFPS: Float, screenMaxFPS: Int) -> Int? {
        let refresh = screenMaxFPS > 0 ? screenMaxFPS : 60
        let target = min(refresh, 60)
        guard sourceFPS > Float(target) + 1 else { return nil }
        return target
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter PlaybackTuningTests`
Expected: PASS (5 tests). Fallback: run `[TYPECHECK]` — expected no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add PlaybackTuning.swift Package.swift build.sh Tests/LivePaperCoreTests/PlaybackTuningTests.swift
git commit -m "feat: pure frame-rate-cap decision helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Apply the FPS cap in ScreenPlayer

**Files:**
- Modify: `ScreenPlayer.swift` (`setupVideoPlayer`, lines 117-145)

**Interfaces:**
- Consumes: `PlaybackTuning.frameRateCapTarget(sourceFPS:screenMaxFPS:)` (Task 1); `ScreenPlayer.screen` (existing stored `NSScreen`), `ScreenPlayer.avPlayer` (existing).
- Produces: none (leaf behavior).

- [ ] **Step 1: Replace `setupVideoPlayer` to build the item once and apply the cap asynchronously**

In `ScreenPlayer.swift`, replace the first line of `setupVideoPlayer`:
```swift
        let item = AVPlayerItem(asset: AVURLAsset(url: fileURL))
        avPlayer = AVPlayer(playerItem: item)
```
with:
```swift
        let asset = AVURLAsset(url: fileURL)
        let item = AVPlayerItem(asset: asset)
        avPlayer = AVPlayer(playerItem: item)
        applyFrameRateCapIfNeeded(asset: asset, item: item)
```
(Leave the rest of `setupVideoPlayer` unchanged.)

- [ ] **Step 2: Add the cap helper method**

In `ScreenPlayer.swift`, add this method immediately after `setupVideoPlayer()` (before `setupImageView()`):
```swift
    /// For clips whose source frame rate exceeds the display (capped at 60),
    /// attach a frame-rate-limiting video composition so AVFoundation stops
    /// pushing frames the display will never show. Normal-rate clips get no
    /// composition. Runs asynchronously to avoid blocking the main thread on
    /// track property loading.
    private func applyFrameRateCapIfNeeded(asset: AVURLAsset, item: AVPlayerItem) {
        let screenMaxFPS = screen.maximumFramesPerSecond
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self, weak item] in
            guard let self, let item else { return }
            var error: NSError?
            guard asset.statusOfValue(forKey: "tracks", error: &error) == .loaded,
                  let track = asset.tracks(withMediaType: .video).first else { return }
            guard let target = PlaybackTuning.frameRateCapTarget(
                    sourceFPS: track.nominalFrameRate, screenMaxFPS: screenMaxFPS) else { return }
            let composition = AVMutableVideoComposition(propertiesOf: asset)
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(target))
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item else { return }
                // Only apply if this item is still the one playing (media may have
                // been swapped by updateMedia in the meantime).
                guard self.avPlayer?.currentItem === item else { return }
                item.videoComposition = composition
            }
        }
    }
```

- [ ] **Step 3: Typecheck**

Run `[TYPECHECK]`.
Expected: no output, exit 0 (deprecation warnings for `loadValuesAsynchronously` / `AVMutableVideoComposition(propertiesOf:)` are acceptable and do not fail the build).

- [ ] **Step 4: Build and smoke-launch**

```bash
./build.sh && pkill -x LivePaper 2>/dev/null; sleep 1; open build/LivePaper.app && sleep 2 && pgrep -x LivePaper && echo "launched OK"
```
Expected: `Done! App: build/LivePaper.app` then `launched OK`. (Behavioral confirmation of the cap itself happens in Task 5's measurement.)

- [ ] **Step 5: Commit**

```bash
git add ScreenPlayer.swift
git commit -m "perf: cap render rate for high-fps clips via video composition

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Event-driven window ordering

**Files:**
- Modify: `WallpaperManager.swift` (`showAll` → `reassertWindowOrder`, `reconcile`, `startKeepVisibleTimer`/`stopKeepVisibleTimer`, the `keepVisibleInterval` constant, and call sites at lines ~295, ~533, ~850, ~905, ~918, ~953)

**Interfaces:**
- Consumes: `coordinator.applied` (existing), `players` (existing).
- Produces: `reassertWindowOrder()`, `startOrderBackstopTimer()`, `stopOrderBackstopTimer()` (all private).

- [ ] **Step 1: Rename `showAll()` to `reassertWindowOrder()`**

In `WallpaperManager.swift` replace:
```swift
    private func showAll() {
        players.forEach { id, player in
            if coordinator.applied[id] == .hidden { return }
            player.window?.orderBack(nil)
        }
    }
```
with:
```swift
    /// Re-assert desktop-level z-order for every visible player window. Called
    /// on ordering-relevant events (via reconcile) and by a slow backstop timer,
    /// replacing the old 0.75s poll.
    private func reassertWindowOrder() {
        players.forEach { id, player in
            if coordinator.applied[id] == .hidden { return }
            player.window?.orderBack(nil)
        }
    }
```

- [ ] **Step 2: Update every `showAll()` call site**

Run to find them:
```bash
grep -n "showAll()" WallpaperManager.swift
```
Replace each remaining `self?.showAll()` / `showAll()` call (the timer body will be replaced in Step 4; the others are direct calls) with `reassertWindowOrder()` (or `self?.reassertWindowOrder()` inside closures). Expected sites: the `resume()`/`appBecameActive`-style direct calls around lines 533, and the asyncAfter blocks around 850 and 905. After this step, `grep -n "showAll" WallpaperManager.swift` returns nothing.

- [ ] **Step 3: Call `reassertWindowOrder()` at the tail of `reconcile()`**

In `reconcile()`, replace:
```swift
        guard isActive else { coordinator.reset(); return }
        let reasonsByScreen = PauseEvaluator.reasonsByScreen(currentPauseInputs())
        let changed = coordinator.reconcile(reasonsByScreen: reasonsByScreen, control: self)
        if changed {
            NotificationCenter.default.post(name: WallpaperManager.playbackStateDidChangeNotification, object: nil)
        }
    }
```
with:
```swift
        guard isActive else { coordinator.reset(); return }
        let reasonsByScreen = PauseEvaluator.reasonsByScreen(currentPauseInputs())
        let changed = coordinator.reconcile(reasonsByScreen: reasonsByScreen, control: self)
        // Re-assert z-order on every reconcile — reconcile already fires on the
        // events that can disturb ordering (space change, app activation, wake,
        // screen change), so this replaces the old periodic poll. orderBack on a
        // correctly-ordered window is a near-noop.
        reassertWindowOrder()
        if changed {
            NotificationCenter.default.post(name: WallpaperManager.playbackStateDidChangeNotification, object: nil)
        }
    }
```

- [ ] **Step 4: Replace the 0.75s timer with an 8s backstop**

Replace the `keepVisibleInterval` constant declaration:
```swift
    private let keepVisibleInterval: TimeInterval = 0.75
```
with:
```swift
    private let orderBackstopInterval: TimeInterval = 8
```
Then replace:
```swift
    private func startKeepVisibleTimer() {
        keepVisibleTimer?.invalidate()
        keepVisibleTimer = Timer.scheduledTimer(withTimeInterval: keepVisibleInterval, repeats: true) { [weak self] _ in
            self?.showAll()
        }
    }

    private func stopKeepVisibleTimer() {
        keepVisibleTimer?.invalidate()
        keepVisibleTimer = nil
    }
```
with:
```swift
    private func startOrderBackstopTimer() {
        keepVisibleTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: orderBackstopInterval, repeats: true) { [weak self] _ in
            self?.reassertWindowOrder()
        }
        timer.tolerance = 2
        keepVisibleTimer = timer
    }

    private func stopOrderBackstopTimer() {
        keepVisibleTimer?.invalidate()
        keepVisibleTimer = nil
    }
```
(The stored property `keepVisibleTimer` keeps its name — only the start/stop methods and cadence change.)

- [ ] **Step 5: Update the start/stop call sites**

Run:
```bash
grep -n "startKeepVisibleTimer\|stopKeepVisibleTimer" WallpaperManager.swift
```
Replace every `startKeepVisibleTimer()` with `startOrderBackstopTimer()` and every `stopKeepVisibleTimer()` with `stopOrderBackstopTimer()` (call sites are around lines 120-121 in `deinit`, ~295, ~850, ~905, ~918, ~953). After this, `grep -n "KeepVisibleTimer" WallpaperManager.swift` returns nothing.

- [ ] **Step 6: Typecheck + build + smoke-launch**

Run `[TYPECHECK]` (expected exit 0), then:
```bash
./build.sh && pkill -x LivePaper 2>/dev/null; sleep 1; open build/LivePaper.app && sleep 2 && pgrep -x LivePaper && echo "launched OK"
```
Expected: build succeeds, `launched OK`.

- [ ] **Step 7: Commit**

```bash
git add WallpaperManager.swift
git commit -m "perf: event-driven window ordering with slow backstop timer

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Timer coalescing

**Files:**
- Modify: `WallpaperManager.swift` (sync-group timer ~768, `startIndependentTimer` ~825, `startRotationTimer(forScreenID:)` ~1025, `startBatteryCheckTimer` ~1108)

**Interfaces:**
- Consumes: existing timer creation sites. Produces: none.

- [ ] **Step 1: Add tolerance to the sync-group rotation timer**

Replace:
```swift
        syncGroupTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.advanceSyncGroup()
        }
```
with:
```swift
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.advanceSyncGroup()
        }
        timer.tolerance = interval * 0.1
        syncGroupTimer = timer
```

- [ ] **Step 2: Add tolerance to `startIndependentTimer(forScreenID:)`**

Replace (the block starting at ~825):
```swift
        independentTimersByScreen[id] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.nextWallpaper(forScreenID: id)
        }
    }

    private func stopIndependentTimer(forScreenID id: String) {
```
with:
```swift
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.nextWallpaper(forScreenID: id)
        }
        timer.tolerance = interval * 0.1
        independentTimersByScreen[id] = timer
    }

    private func stopIndependentTimer(forScreenID id: String) {
```

- [ ] **Step 3: Add tolerance to `startRotationTimer(forScreenID:)`**

Replace (the block starting at ~1025):
```swift
        independentTimersByScreen[id] = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.nextWallpaper(forScreenID: id)
        }
    }

    private func urlForScreen(_ screen: NSScreen) -> URL? {
```
with:
```swift
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.nextWallpaper(forScreenID: id)
        }
        timer.tolerance = interval * 0.1
        independentTimersByScreen[id] = timer
    }

    private func urlForScreen(_ screen: NSScreen) -> URL? {
```

- [ ] **Step 4: Lengthen the battery poll and add tolerance**

Replace:
```swift
    private func startBatteryCheckTimer() {
        guard batteryCheckTimer == nil else { return }
        batteryCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.reconcile()
        }
    }
```
with:
```swift
    private func startBatteryCheckTimer() {
        guard batteryCheckTimer == nil else { return }
        // Battery LEVEL changes slowly; instantaneous events (Low Power Mode, AC
        // connect/disconnect) already arrive via NSProcessInfoPowerStateDidChange,
        // so a 2-minute level poll with wide tolerance is plenty responsive.
        let timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.reconcile()
        }
        timer.tolerance = 15
        batteryCheckTimer = timer
    }
```

- [ ] **Step 5: Typecheck + build**

Run `[TYPECHECK]` (expected exit 0), then `./build.sh` (expected `Done! App: build/LivePaper.app`).

- [ ] **Step 6: Commit**

```bash
git add WallpaperManager.swift
git commit -m "perf: coalesce repeating timers (tolerance + 120s battery poll)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: After-measurement and FPS-cap go/no-go

**Files:** temporary harness only (not committed); may revert `ScreenPlayer.swift` if §2 regresses.

- [ ] **Step 1: Add the temporary measurement harness**

In `AppDelegate.swift`, in `applicationDidFinishLaunching`, after `mainWindow.runOnboardingIfNeeded()`:
```swift
        if let p = ProcessInfo.processInfo.environment["LIVEPAPER_TEST_VIDEO"] {
            wallpaperManager.setWallpaper(url: URL(fileURLWithPath: p)) // PERF-HARNESS
        }
```
Then `./build.sh`.

- [ ] **Step 2: Generate the same test clip used for the baseline**

```bash
SP="$(mktemp -d)"
ffmpeg -y -f lavfi -i testsrc2=size=1920x1080:rate=120 -t 8 \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p "$SP/test1080p120.mp4"
echo "$SP/test1080p120.mp4"
```

- [ ] **Step 3: Measure AFTER (playing, unobscured)**

```bash
pkill -x LivePaper 2>/dev/null; sleep 1
LIVEPAPER_TEST_VIDEO="$SP/test1080p120.mp4" build/LivePaper.app/Contents/MacOS/LivePaper >/dev/null 2>&1 &
sleep 5
PID=$(pgrep -x LivePaper)
top -l 13 -s 2 -pid "$PID" -stats pid,cpu,mem,idlew 2>/dev/null \
 | awk 'BEGIN{n=0} /^[0-9]+ / && $1=='"$PID"'{n++; print n": cpu="$2" mem="$3" idlew="$4}'
```
Discard sample 1 (warmup); average CPU over samples 2-13.

- [ ] **Step 4: Compare against baseline and decide**

Baseline (from the spec): **~8.0% CPU, ~41 MB RSS** for this clip.
- If AFTER CPU is **measurably lower** than ~8.0% → FPS cap is a win; keep it.
- If AFTER CPU is **not lower (or higher)** → the composition is net-negative on this hardware. **Revert Task 2**:
  ```bash
  git revert --no-edit <task-2-commit-sha>
  ```
  Record the revert and the numbers that justified it.
- RSS must be **≤ ~41 MB** (no regression).
- Record AFTER numbers and the delta in the commit message / a short note appended to the spec's Baseline section.

- [ ] **Step 5: Remove the harness hook**

Delete the `PERF-HARNESS` block added in Step 1 from `AppDelegate.swift`, then `./build.sh` to confirm a clean build, and verify:
```bash
grep -n "PERF-HARNESS\|LIVEPAPER_TEST_VIDEO" AppDelegate.swift
```
Expected: no output.

- [ ] **Step 6: Idle-wakeups sanity check (optional, best-effort)**

With the wallpaper active but the app otherwise idle, confirm the process is not waking ~1.3×/sec from the old poll. If `sudo` is available: `sudo powermetrics --samplers tasks -n 1 -i 1000 | grep -i livepaper` and compare wake-ups to expectation; otherwise note that the 0.75s timer removal is verified by code inspection (Task 3) and skip. Do not block completion on this.

- [ ] **Step 7: Final commit (if the harness removal or a note changed anything)**

```bash
git add -A
git commit -m "chore: remove perf harness; record after-measurement

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

- **Spec coverage:** §1 event-driven ordering → Task 3; §2 FPS cap → Tasks 1 (decision) + 2 (wiring); §3 timer coalescing → Task 4; baseline + verification + go/no-go → Task 5; deferred decode-buffer release → intentionally not planned (documented). All spec sections map to a task.
- **Placeholder scan:** no TBD/verbatim-duplication/"handle edge cases" — every code step has complete code and exact commands.
- **Type consistency:** `PlaybackTuning.frameRateCapTarget(sourceFPS: Float, screenMaxFPS: Int) -> Int?` is defined in Task 1 and consumed with those exact types in Task 2. `reassertWindowOrder()` / `startOrderBackstopTimer()` / `stopOrderBackstopTimer()` are defined and all call sites updated within Task 3. Timer-tolerance edits (Task 4) touch only creation sites and change no signatures.
- **Grep-guarded renames:** Tasks 3 uses `grep` to prove no stale `showAll` / `KeepVisibleTimer` references remain.
