# Pause / Power Model Rework Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace LivePaper's scattered pause/resume flags with a single per-screen "pause reasons" model (derive-and-reconcile) that is correct, readable, extensible, and simpler.

**Architecture:** Pure, testable logic lives in three new files added to the `LivePaperCore` package target: policy/reason types (`PausePolicy.swift`), reason derivation + status aggregation (`PauseEvaluator.swift`), and a transition-diffing coordinator (`PauseCoordinator.swift`). `WallpaperManager` (AppKit/AVFoundation, excluded from the test target) holds only raw *inputs*, builds a `PauseInputs` snapshot, and funnels every event through one idempotent `reconcile()` that asks the evaluator for reasons and the coordinator to apply the delta. Thermal pausing is removed. Sync-on-resume (`resumePlayerAligned`) is preserved as the hook a future frame-lock spec will extend.

**Tech Stack:** Swift 5.9, AppKit, AVFoundation, IOKit.ps; SwiftPM library `LivePaperCore` + XCTest test target; app built via `./build.sh` (raw `swiftc`).

## Global Constraints

- **Design spec:** `docs/superpowers/specs/2026-07-22-pause-power-model-design.md` — authoritative; every task serves it.
- **Deployment target:** macOS 12.0. New code must compile under `-target arm64-apple-macos12.0`. Do not use APIs newer than macOS 12 without an `#available` guard.
- **Reason set (exact, closed):** `manualAll`, `manualScreen`, `lowBattery`, `asleep`, `covered`, `desktopUnfocused`. No `thermal`.
- **Battery low threshold:** `20` (percent). Fixed constant, not user-facing.
- **`isCharging` semantics:** throughout, "isCharging" means *on external/AC power* (matches the existing `currentBatterySnapshot` logic, which treats AC power as charging).
- **Access modifiers:** match existing files — no explicit `public`/`internal` (default internal). Tests use `@testable import LivePaperCore`.
- **New pure files MUST be added to `Package.swift`'s `sources:` array** or they won't compile into the app or be visible to tests.
- **Test runner:** `swift test` requires XCTest (full Xcode or a toolchain that ships XCTest). On a Command-Line-Tools-only machine `swift test` fails with "unable to resolve module dependency: 'XCTest'". If `swift test` is unavailable, the fallback verification for a task's *logic* is the whole-app typecheck (below); still write the test files — they gate on any machine with Xcode.
- **Whole-app typecheck command** (used as build verification; referenced as `[TYPECHECK]`):
  ```bash
  swiftc -typecheck -target "$(uname -m)-apple-macos12.0" \
    Screen_Config.swift SettingsManager.swift MediaType.swift PlaylistBuilder.swift \
    Localization.swift PerformanceMonitor.swift ScreenPlayer.swift WallpaperManager.swift \
    MainWindowController.swift ThumbnailItem.swift ThumbnailProvider.swift \
    AboutWindowController.swift AppDelegate.swift main.swift \
    PausePolicy.swift PauseEvaluator.swift PauseCoordinator.swift \
    -framework Cocoa -framework AVKit -framework AVFoundation \
    -framework ServiceManagement -framework ImageIO -framework IOKit
  ```
  Expected on success: no output, exit 0. (Add the three new files to `build.sh`'s `swiftc` invocation too — see Task 6.)
- **Commit discipline:** commit at the end of each task on branch `pause-power-model`. Co-author trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **Starting point:** the branch working tree contains the earlier "pause-when-covered / thermal / sync-on-resume" implementation, uncommitted. This plan *reworks and partly removes* it. Do not preserve `pauseWhenInvisible`, `pauseWhenOccluded`, `pauseUnderThermalPressure`, `isPausedInternally`, `shouldPauseForThermal`, or the thermal UI.

---

## File Structure

**New (add to `LivePaperCore` package `sources` and `build.sh`):**
- `PausePolicy.swift` — `PauseReason`, `BatteryPausePolicy`, `VisibilityPausePolicy`, `PowerState`. Pure types + derived properties (`hidesWindow`, `statusPriority`).
- `PauseEvaluator.swift` — `PauseInputs` struct, `PlaybackSummary` enum, and pure functions `batteryConditionMet`, `reasons(for:_:)`, `reasonsByScreen(_:)`, `summarize(_:isActive:)`.
- `PauseCoordinator.swift` — `ScreenPlaybackState`, `ScreenPlaybackControl` protocol, `PauseCoordinator` (transition diffing).

**Modified:**
- `Package.swift` — register the three new files.
- `SettingsManager.swift` — `batteryPausePolicy` / `visibilityPausePolicy` accessors + `migratePausePoliciesIfNeeded()`; remove the three old bool accessors.
- `ScreenPlayer.swift` — no behavioral change required (existing `pausePlayback`, `resumePlayback(alignedTo:)`, `window` cover freeze/hide/play). Occlusion observer stays.
- `WallpaperManager.swift` — raw-input state, `reconcile()`, `ScreenPlaybackControl` conformance, notification wiring, public-API reimplementation, thermal removal.
- `AppDelegate.swift` — two policy radio submenus; status via `PlaybackSummary`; per-screen reason suffix; remove thermal/old items.
- `MainWindowController.swift` — two `NSPopUpButton`s replacing the three checkboxes.
- `Resources/en.lproj/Localizable.strings`, `Resources/zh-Hans.lproj/Localizable.strings` — new keys; remove thermal/old keys.

**Tests (new):**
- `Tests/LivePaperCoreTests/PausePolicyTests.swift`
- `Tests/LivePaperCoreTests/PauseEvaluatorTests.swift`
- `Tests/LivePaperCoreTests/PauseCoordinatorTests.swift`
- `SettingsManagerTests.swift` — add migration tests.

---

## Task 1: Policy & reason types

**Files:**
- Create: `PausePolicy.swift`
- Modify: `Package.swift` (add three new sources)
- Test: `Tests/LivePaperCoreTests/PausePolicyTests.swift`

**Interfaces:**
- Produces: `enum BatteryPausePolicy: String { off, lowBattery, onBattery, followLowPowerMode }`; `enum VisibilityPausePolicy: String { off, covered, unfocused }`; `enum PauseReason: String, Hashable` with `var hidesWindow: Bool` and `var statusPriority: Int`; `struct PowerState { batteryLevel: Int?; isCharging: Bool; lowPowerModeEnabled: Bool }`.

- [ ] **Step 1: Add the three new files to `Package.swift` sources**

In `Package.swift`, change the `sources:` array of the `LivePaperCore` target from:
```swift
            sources: [
                "Screen_Config.swift",
                "SettingsManager.swift",
                "MediaType.swift",
                "PlaylistBuilder.swift"
            ],
```
to:
```swift
            sources: [
                "Screen_Config.swift",
                "SettingsManager.swift",
                "MediaType.swift",
                "PlaylistBuilder.swift",
                "PausePolicy.swift",
                "PauseEvaluator.swift",
                "PauseCoordinator.swift"
            ],
```

- [ ] **Step 2: Write the failing test**

Create `Tests/LivePaperCoreTests/PausePolicyTests.swift`:
```swift
import XCTest
@testable import LivePaperCore

final class PausePolicyTests: XCTestCase {
    func testHidesWindowOnlyForManualReasons() {
        XCTAssertTrue(PauseReason.manualAll.hidesWindow)
        XCTAssertTrue(PauseReason.manualScreen.hidesWindow)
        XCTAssertFalse(PauseReason.lowBattery.hidesWindow)
        XCTAssertFalse(PauseReason.asleep.hidesWindow)
        XCTAssertFalse(PauseReason.covered.hidesWindow)
        XCTAssertFalse(PauseReason.desktopUnfocused.hidesWindow)
    }

    func testStatusPriorityOrder() {
        XCTAssertGreaterThan(PauseReason.manualAll.statusPriority, PauseReason.manualScreen.statusPriority)
        XCTAssertGreaterThan(PauseReason.manualScreen.statusPriority, PauseReason.lowBattery.statusPriority)
        XCTAssertGreaterThan(PauseReason.lowBattery.statusPriority, PauseReason.asleep.statusPriority)
        XCTAssertGreaterThan(PauseReason.asleep.statusPriority, PauseReason.covered.statusPriority)
        XCTAssertEqual(PauseReason.covered.statusPriority, PauseReason.desktopUnfocused.statusPriority)
    }

    func testPolicyRawValuesAreStable() {
        XCTAssertEqual(BatteryPausePolicy(rawValue: "followLowPowerMode"), .followLowPowerMode)
        XCTAssertEqual(VisibilityPausePolicy(rawValue: "unfocused"), .unfocused)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter PausePolicyTests`
Expected: FAIL — `cannot find 'PauseReason' in scope` (or, on a CLT-only box, the XCTest resolution error; in that case skip to Step 4 and rely on `[TYPECHECK]`).

- [ ] **Step 4: Write the implementation**

Create `PausePolicy.swift`:
```swift
import Foundation

/// How aggressively to pause when running on battery.
enum BatteryPausePolicy: String, CaseIterable {
    case off
    case lowBattery         // <= 20% and not on AC
    case onBattery          // any level, whenever not on AC
    case followLowPowerMode // whenever macOS Low Power Mode is on
}

/// When to pause based on whether the wallpaper is actually being seen.
enum VisibilityPausePolicy: String, CaseIterable {
    case off
    case covered   // this screen's window fully occluded (per-screen)
    case unfocused // another app is frontmost (global)
}

/// A single, closed set of reasons a screen's playback may be paused.
enum PauseReason: String, Hashable, CaseIterable {
    case manualAll
    case manualScreen
    case lowBattery
    case asleep
    case covered
    case desktopUnfocused

    /// Reasons whose pause should also hide the wallpaper window (revealing the
    /// static desktop copy). All other reasons merely freeze the current frame.
    var hidesWindow: Bool {
        switch self {
        case .manualAll, .manualScreen: return true
        case .lowBattery, .asleep, .covered, .desktopUnfocused: return false
        }
    }

    /// Higher wins when choosing the dominant reason for the status label.
    var statusPriority: Int {
        switch self {
        case .manualAll:        return 5
        case .manualScreen:     return 4
        case .lowBattery:       return 3
        case .asleep:           return 2
        case .covered:          return 1
        case .desktopUnfocused: return 1
        }
    }
}

/// Raw power inputs, sampled live. `isCharging` means "on external/AC power".
/// `batteryLevel` is nil when there is no battery (desktop Macs).
struct PowerState: Equatable {
    var batteryLevel: Int?
    var isCharging: Bool
    var lowPowerModeEnabled: Bool
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter PausePolicyTests`
Expected: PASS (3 tests). If `swift test` is unavailable, run `[TYPECHECK]` instead — expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add PausePolicy.swift Package.swift Tests/LivePaperCoreTests/PausePolicyTests.swift
git commit -m "feat: add pause-reason and policy types

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: SettingsManager policies + migration

**Files:**
- Modify: `SettingsManager.swift`
- Test: `Tests/LivePaperCoreTests/SettingsManagerTests.swift`

**Interfaces:**
- Consumes: `BatteryPausePolicy`, `VisibilityPausePolicy` (Task 1).
- Produces: `var batteryPausePolicy: BatteryPausePolicy`; `var visibilityPausePolicy: VisibilityPausePolicy`; `func migratePausePoliciesIfNeeded()`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/LivePaperCoreTests/SettingsManagerTests.swift` (before the final closing `}`):
```swift
    func testPausePolicyDefaultsAreOff() {
        XCTAssertEqual(settings.batteryPausePolicy, .off)
        XCTAssertEqual(settings.visibilityPausePolicy, .off)
    }

    func testPausePolicyRoundTrip() {
        settings.batteryPausePolicy = .followLowPowerMode
        settings.visibilityPausePolicy = .unfocused
        XCTAssertEqual(settings.batteryPausePolicy, .followLowPowerMode)
        XCTAssertEqual(settings.visibilityPausePolicy, .unfocused)
    }

    func testMigrationTranslatesOldBatterySaverToLowBattery() {
        defaults.set(true, forKey: "livepaper_pause_when_invisible")
        settings.migratePausePoliciesIfNeeded()
        XCTAssertEqual(settings.batteryPausePolicy, .lowBattery)
        XCTAssertNil(defaults.object(forKey: "livepaper_pause_when_invisible"))
    }

    func testMigrationTranslatesOldOcclusionToCovered() {
        defaults.set(true, forKey: "livepaper_pause_when_occluded")
        settings.migratePausePoliciesIfNeeded()
        XCTAssertEqual(settings.visibilityPausePolicy, .covered)
        XCTAssertNil(defaults.object(forKey: "livepaper_pause_when_occluded"))
    }

    func testMigrationFalseOldKeysBecomeOff() {
        defaults.set(false, forKey: "livepaper_pause_when_invisible")
        defaults.set(false, forKey: "livepaper_pause_when_occluded")
        settings.migratePausePoliciesIfNeeded()
        XCTAssertEqual(settings.batteryPausePolicy, .off)
        XCTAssertEqual(settings.visibilityPausePolicy, .off)
    }

    func testMigrationDeletesThermalKey() {
        defaults.set(true, forKey: "livepaper_pause_under_thermal")
        settings.migratePausePoliciesIfNeeded()
        XCTAssertNil(defaults.object(forKey: "livepaper_pause_under_thermal"))
    }

    func testMigrationDoesNotClobberExistingNewPolicy() {
        settings.batteryPausePolicy = .onBattery
        defaults.set(true, forKey: "livepaper_pause_when_invisible") // stale old key
        settings.migratePausePoliciesIfNeeded()
        XCTAssertEqual(settings.batteryPausePolicy, .onBattery) // new key wins, not overwritten
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SettingsManagerTests`
Expected: FAIL — `value of type 'SettingsManager' has no member 'batteryPausePolicy'`.

- [ ] **Step 3: Implement policies + migration in `SettingsManager.swift`**

In the "UserDefaults Keys" block, replace these three lines:
```swift
    private let pauseWhenInvisibleKey    = "livepaper_pause_when_invisible"
    private let pauseWhenOccludedKey     = "livepaper_pause_when_occluded"
    private let pauseUnderThermalKey     = "livepaper_pause_under_thermal"
```
with:
```swift
    private let batteryPausePolicyKey    = "livepaper_battery_pause_policy"
    private let visibilityPausePolicyKey = "livepaper_visibility_pause_policy"
    // Legacy keys, migrated away in migratePausePoliciesIfNeeded().
    private let legacyPauseInvisibleKey  = "livepaper_pause_when_invisible"
    private let legacyPauseOccludedKey   = "livepaper_pause_when_occluded"
    private let legacyPauseThermalKey    = "livepaper_pause_under_thermal"
```

Delete the three old computed properties (`pauseWhenInvisible`, `pauseWhenOccluded`, `pauseUnderThermalPressure`) entirely.

Add the new accessors and migration (place after `syncDesktopWallpaper`):
```swift
    var batteryPausePolicy: BatteryPausePolicy {
        get {
            guard let raw = defaults.string(forKey: batteryPausePolicyKey),
                  let p = BatteryPausePolicy(rawValue: raw) else { return .off }
            return p
        }
        set { defaults.set(newValue.rawValue, forKey: batteryPausePolicyKey) }
    }

    var visibilityPausePolicy: VisibilityPausePolicy {
        get {
            guard let raw = defaults.string(forKey: visibilityPausePolicyKey),
                  let p = VisibilityPausePolicy(rawValue: raw) else { return .off }
            return p
        }
        set { defaults.set(newValue.rawValue, forKey: visibilityPausePolicyKey) }
    }

    /// One-time translation from the legacy boolean toggles to the new policy
    /// enums. A new key that already exists always wins; legacy keys are always
    /// removed. Safe to call on every launch.
    func migratePausePoliciesIfNeeded() {
        if defaults.object(forKey: batteryPausePolicyKey) == nil,
           defaults.object(forKey: legacyPauseInvisibleKey) != nil {
            batteryPausePolicy = defaults.bool(forKey: legacyPauseInvisibleKey) ? .lowBattery : .off
        }
        if defaults.object(forKey: visibilityPausePolicyKey) == nil,
           defaults.object(forKey: legacyPauseOccludedKey) != nil {
            visibilityPausePolicy = defaults.bool(forKey: legacyPauseOccludedKey) ? .covered : .off
        }
        defaults.removeObject(forKey: legacyPauseInvisibleKey)
        defaults.removeObject(forKey: legacyPauseOccludedKey)
        defaults.removeObject(forKey: legacyPauseThermalKey)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SettingsManagerTests`
Expected: PASS (all existing + 7 new). Fallback: `[TYPECHECK]` will still fail here until Task 6 removes the old-property call sites — that's expected. If on a CLT-only box, defer verification of this task to Task 6's typecheck and note it.

- [ ] **Step 5: Commit**

```bash
git add SettingsManager.swift Tests/LivePaperCoreTests/SettingsManagerTests.swift
git commit -m "feat: battery/visibility pause policies + legacy migration

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: PauseEvaluator (pure derivation + status)

**Files:**
- Create: `PauseEvaluator.swift`
- Test: `Tests/LivePaperCoreTests/PauseEvaluatorTests.swift`

**Interfaces:**
- Consumes: `PauseReason`, `BatteryPausePolicy`, `VisibilityPausePolicy`, `PowerState` (Task 1).
- Produces:
  - `struct PauseInputs { screenIDs:[String]; manualAll:Bool; manualScreens:Set<String>; systemAsleep:Bool; power:PowerState; batteryPolicy:BatteryPausePolicy; visibilityPolicy:VisibilityPausePolicy; occludedScreens:Set<String>; desktopFrontmost:Bool }`
  - `enum PlaybackSummary: Equatable { stopped; playing; paused(PauseReason); partiallyPaused }`
  - `enum PauseEvaluator` with static `batteryConditionMet(_:_:) -> Bool`, `reasons(for:_:) -> Set<PauseReason>`, `reasonsByScreen(_:) -> [String:Set<PauseReason>]`, `summarize(_:isActive:) -> PlaybackSummary`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/LivePaperCoreTests/PauseEvaluatorTests.swift`:
```swift
import XCTest
@testable import LivePaperCore

final class PauseEvaluatorTests: XCTestCase {
    private func inputs(
        screens: [String] = ["A"],
        manualAll: Bool = false,
        manualScreens: Set<String> = [],
        asleep: Bool = false,
        level: Int? = 100,
        charging: Bool = true,
        lowPower: Bool = false,
        battery: BatteryPausePolicy = .off,
        visibility: VisibilityPausePolicy = .off,
        occluded: Set<String> = [],
        desktopFrontmost: Bool = true
    ) -> PauseInputs {
        PauseInputs(
            screenIDs: screens, manualAll: manualAll, manualScreens: manualScreens,
            systemAsleep: asleep,
            power: PowerState(batteryLevel: level, isCharging: charging, lowPowerModeEnabled: lowPower),
            batteryPolicy: battery, visibilityPolicy: visibility,
            occludedScreens: occluded, desktopFrontmost: desktopFrontmost)
    }

    func testNoReasonsWhenEverythingNominal() {
        XCTAssertTrue(PauseEvaluator.reasons(for: "A", inputs()).isEmpty)
    }

    func testManualAllAndScreen() {
        XCTAssertEqual(PauseEvaluator.reasons(for: "A", inputs(manualAll: true)), [.manualAll])
        XCTAssertEqual(PauseEvaluator.reasons(for: "A", inputs(manualScreens: ["A"])), [.manualScreen])
        XCTAssertTrue(PauseEvaluator.reasons(for: "B", inputs(screens: ["A","B"], manualScreens: ["A"])).isEmpty)
    }

    func testAsleep() {
        XCTAssertEqual(PauseEvaluator.reasons(for: "A", inputs(asleep: true)), [.asleep])
    }

    func testBatteryLowBatteryPolicy() {
        XCTAssertFalse(PauseEvaluator.batteryConditionMet(.lowBattery, PowerState(batteryLevel: 15, isCharging: true, lowPowerModeEnabled: false)))
        XCTAssertTrue(PauseEvaluator.batteryConditionMet(.lowBattery, PowerState(batteryLevel: 15, isCharging: false, lowPowerModeEnabled: false)))
        XCTAssertFalse(PauseEvaluator.batteryConditionMet(.lowBattery, PowerState(batteryLevel: 40, isCharging: false, lowPowerModeEnabled: false)))
    }

    func testBatteryOnBatteryPolicy() {
        XCTAssertTrue(PauseEvaluator.batteryConditionMet(.onBattery, PowerState(batteryLevel: 90, isCharging: false, lowPowerModeEnabled: false)))
        XCTAssertFalse(PauseEvaluator.batteryConditionMet(.onBattery, PowerState(batteryLevel: 90, isCharging: true, lowPowerModeEnabled: false)))
        // desktop Mac: no battery -> never
        XCTAssertFalse(PauseEvaluator.batteryConditionMet(.onBattery, PowerState(batteryLevel: nil, isCharging: false, lowPowerModeEnabled: false)))
    }

    func testBatteryFollowLowPowerMode() {
        XCTAssertTrue(PauseEvaluator.batteryConditionMet(.followLowPowerMode, PowerState(batteryLevel: 90, isCharging: true, lowPowerModeEnabled: true)))
        XCTAssertFalse(PauseEvaluator.batteryConditionMet(.followLowPowerMode, PowerState(batteryLevel: 5, isCharging: false, lowPowerModeEnabled: false)))
    }

    func testBatteryOffPolicyNeverPauses() {
        XCTAssertFalse(PauseEvaluator.batteryConditionMet(.off, PowerState(batteryLevel: 1, isCharging: false, lowPowerModeEnabled: true)))
    }

    func testVisibilityCoveredIsPerScreen() {
        let i = inputs(screens: ["A","B"], visibility: .covered, occluded: ["A"])
        XCTAssertEqual(PauseEvaluator.reasons(for: "A", i), [.covered])
        XCTAssertTrue(PauseEvaluator.reasons(for: "B", i).isEmpty)
    }

    func testVisibilityUnfocusedIsGlobal() {
        let i = inputs(screens: ["A","B"], visibility: .unfocused, desktopFrontmost: false)
        XCTAssertEqual(PauseEvaluator.reasons(for: "A", i), [.desktopUnfocused])
        XCTAssertEqual(PauseEvaluator.reasons(for: "B", i), [.desktopUnfocused])
    }

    func testVisibilityOffIgnoresOcclusion() {
        let i = inputs(visibility: .off, occluded: ["A"], desktopFrontmost: false)
        XCTAssertTrue(PauseEvaluator.reasons(for: "A", i).isEmpty)
    }

    func testOverlappingReasonsAllPresent() {
        let i = inputs(manualAll: true, asleep: true, level: 10, charging: false,
                       battery: .lowBattery, visibility: .covered, occluded: ["A"])
        XCTAssertEqual(PauseEvaluator.reasons(for: "A", i), [.manualAll, .asleep, .lowBattery, .covered])
    }

    func testSummarizeStoppedWhenInactive() {
        XCTAssertEqual(PauseEvaluator.summarize([:], isActive: false), .stopped)
    }

    func testSummarizePlayingWhenNoneePaused() {
        XCTAssertEqual(PauseEvaluator.summarize(["A": [], "B": []], isActive: true), .playing)
    }

    func testSummarizePartiallyPaused() {
        XCTAssertEqual(PauseEvaluator.summarize(["A": [.covered], "B": []], isActive: true), .partiallyPaused)
    }

    func testSummarizeAllPausedDominantReason() {
        XCTAssertEqual(PauseEvaluator.summarize(["A": [.lowBattery], "B": [.manualAll]], isActive: true), .paused(.manualAll))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PauseEvaluatorTests`
Expected: FAIL — `cannot find 'PauseEvaluator' in scope`.

- [ ] **Step 3: Implement `PauseEvaluator.swift`**

Create `PauseEvaluator.swift`:
```swift
import Foundation

/// A snapshot of every input that determines pause state, sampled at one
/// instant so derivation is a pure function of this value.
struct PauseInputs {
    var screenIDs: [String]
    var manualAll: Bool
    var manualScreens: Set<String>
    var systemAsleep: Bool
    var power: PowerState
    var batteryPolicy: BatteryPausePolicy
    var visibilityPolicy: VisibilityPausePolicy
    var occludedScreens: Set<String>
    var desktopFrontmost: Bool
}

/// Aggregate playback state across all screens, for the menu-bar status line.
enum PlaybackSummary: Equatable {
    case stopped
    case playing
    case paused(PauseReason) // all screens paused; dominant reason
    case partiallyPaused     // some paused, some playing
}

enum PauseEvaluator {
    static let lowBatteryThreshold = 20

    static func batteryConditionMet(_ policy: BatteryPausePolicy, _ power: PowerState) -> Bool {
        switch policy {
        case .off:
            return false
        case .lowBattery:
            guard let level = power.batteryLevel else { return false }
            return !power.isCharging && level <= lowBatteryThreshold
        case .onBattery:
            return !power.isCharging && power.batteryLevel != nil
        case .followLowPowerMode:
            return power.lowPowerModeEnabled
        }
    }

    static func reasons(for id: String, _ i: PauseInputs) -> Set<PauseReason> {
        var r: Set<PauseReason> = []
        if i.manualAll { r.insert(.manualAll) }
        if i.manualScreens.contains(id) { r.insert(.manualScreen) }
        if i.systemAsleep { r.insert(.asleep) }
        if batteryConditionMet(i.batteryPolicy, i.power) { r.insert(.lowBattery) }
        switch i.visibilityPolicy {
        case .off:
            break
        case .covered:
            if i.occludedScreens.contains(id) { r.insert(.covered) }
        case .unfocused:
            if !i.desktopFrontmost { r.insert(.desktopUnfocused) }
        }
        return r
    }

    static func reasonsByScreen(_ i: PauseInputs) -> [String: Set<PauseReason>] {
        var out: [String: Set<PauseReason>] = [:]
        for id in i.screenIDs { out[id] = reasons(for: id, i) }
        return out
    }

    static func summarize(_ reasonsByScreen: [String: Set<PauseReason>], isActive: Bool) -> PlaybackSummary {
        guard isActive, !reasonsByScreen.isEmpty else { return .stopped }
        let pausedScreens = reasonsByScreen.filter { !$0.value.isEmpty }
        if pausedScreens.isEmpty { return .playing }
        if pausedScreens.count < reasonsByScreen.count { return .partiallyPaused }
        let dominant = pausedScreens.values
            .flatMap { $0 }
            .max { $0.statusPriority < $1.statusPriority }
        return dominant.map { .paused($0) } ?? .partiallyPaused
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PauseEvaluatorTests`
Expected: PASS (15 tests). Fallback: `[TYPECHECK]` (will still fail until Task 6 — expected).

- [ ] **Step 5: Commit**

```bash
git add PauseEvaluator.swift Tests/LivePaperCoreTests/PauseEvaluatorTests.swift
git commit -m "feat: pure pause-reason evaluator and status summary

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: PauseCoordinator (transition diffing)

**Files:**
- Create: `PauseCoordinator.swift`
- Test: `Tests/LivePaperCoreTests/PauseCoordinatorTests.swift`

**Interfaces:**
- Consumes: `PauseReason` (Task 1).
- Produces:
  - `enum ScreenPlaybackState: Equatable { playing; frozen; hidden }`
  - `protocol ScreenPlaybackControl: AnyObject { func apply(_ state: ScreenPlaybackState, to screenID: String) }`
  - `final class PauseCoordinator` with `static func desiredState(for: Set<PauseReason>) -> ScreenPlaybackState`, `@discardableResult func reconcile(reasonsByScreen:control:) -> Bool`, `func reset()`, `var applied: [String: ScreenPlaybackState]` (read).

- [ ] **Step 1: Write the failing tests**

Create `Tests/LivePaperCoreTests/PauseCoordinatorTests.swift`:
```swift
import XCTest
@testable import LivePaperCore

private final class FakeControl: ScreenPlaybackControl {
    var calls: [(String, ScreenPlaybackState)] = []
    func apply(_ state: ScreenPlaybackState, to screenID: String) {
        calls.append((screenID, state))
    }
}

final class PauseCoordinatorTests: XCTestCase {
    func testDesiredState() {
        XCTAssertEqual(PauseCoordinator.desiredState(for: []), .playing)
        XCTAssertEqual(PauseCoordinator.desiredState(for: [.lowBattery]), .frozen)
        XCTAssertEqual(PauseCoordinator.desiredState(for: [.covered, .manualAll]), .hidden)
        XCTAssertEqual(PauseCoordinator.desiredState(for: [.manualScreen]), .hidden)
    }

    func testFirstReconcileAppliesAll() {
        let c = PauseCoordinator(); let ctrl = FakeControl()
        let changed = c.reconcile(reasonsByScreen: ["A": [], "B": [.lowBattery]], control: ctrl)
        XCTAssertTrue(changed)
        XCTAssertEqual(ctrl.calls.count, 2)
    }

    func testSecondReconcileIsIdempotent() {
        let c = PauseCoordinator(); let ctrl = FakeControl()
        _ = c.reconcile(reasonsByScreen: ["A": [], "B": [.lowBattery]], control: ctrl)
        ctrl.calls.removeAll()
        let changed = c.reconcile(reasonsByScreen: ["A": [], "B": [.lowBattery]], control: ctrl)
        XCTAssertFalse(changed)
        XCTAssertTrue(ctrl.calls.isEmpty) // no redundant re-apply / re-seek
    }

    func testOnlyChangedScreensReapply() {
        let c = PauseCoordinator(); let ctrl = FakeControl()
        _ = c.reconcile(reasonsByScreen: ["A": [], "B": []], control: ctrl)
        ctrl.calls.removeAll()
        _ = c.reconcile(reasonsByScreen: ["A": [.covered], "B": []], control: ctrl)
        XCTAssertEqual(ctrl.calls.count, 1)
        XCTAssertEqual(ctrl.calls.first?.0, "A")
        XCTAssertEqual(ctrl.calls.first?.1, .frozen)
    }

    func testRemovedScreenIsForgotten() {
        let c = PauseCoordinator(); let ctrl = FakeControl()
        _ = c.reconcile(reasonsByScreen: ["A": [], "B": []], control: ctrl)
        _ = c.reconcile(reasonsByScreen: ["A": []], control: ctrl) // B removed
        XCTAssertNil(c.applied["B"])
        // Re-adding B applies fresh
        ctrl.calls.removeAll()
        _ = c.reconcile(reasonsByScreen: ["A": [], "B": []], control: ctrl)
        XCTAssertEqual(ctrl.calls.map { $0.0 }, ["B"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PauseCoordinatorTests`
Expected: FAIL — `cannot find 'PauseCoordinator' in scope`.

- [ ] **Step 3: Implement `PauseCoordinator.swift`**

Create `PauseCoordinator.swift`:
```swift
import Foundation

/// What a screen's window/player should be doing right now.
enum ScreenPlaybackState: Equatable {
    case playing // window ordered in, video playing (sync-aligned on entry)
    case frozen  // window ordered in, video paused on last frame
    case hidden  // window ordered out, video paused (static desktop shows)
}

/// Applies a desired playback state to one screen. Implemented by
/// WallpaperManager over its ScreenPlayers.
protocol ScreenPlaybackControl: AnyObject {
    func apply(_ state: ScreenPlaybackState, to screenID: String)
}

/// Diffs desired playback states against what has been applied and drives only
/// the transitions. Holds no policy — it is fed reason sets and translates them.
final class PauseCoordinator {
    private(set) var applied: [String: ScreenPlaybackState] = [:]

    static func desiredState(for reasons: Set<PauseReason>) -> ScreenPlaybackState {
        if reasons.isEmpty { return .playing }
        if reasons.contains(where: { $0.hidesWindow }) { return .hidden }
        return .frozen
    }

    /// Applies desired states for every screen in `reasonsByScreen`, calling
    /// `control` only where the state changed. Forgets screens no longer present.
    /// Returns true if anything changed.
    @discardableResult
    func reconcile(reasonsByScreen: [String: Set<PauseReason>], control: ScreenPlaybackControl) -> Bool {
        var changed = false
        for (id, reasons) in reasonsByScreen {
            let desired = PauseCoordinator.desiredState(for: reasons)
            if applied[id] != desired {
                applied[id] = desired
                control.apply(desired, to: id)
                changed = true
            }
        }
        let present = Set(reasonsByScreen.keys)
        for id in Array(applied.keys) where !present.contains(id) {
            applied.removeValue(forKey: id)
        }
        return changed
    }

    func reset() { applied.removeAll() }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PauseCoordinatorTests`
Expected: PASS (5 tests). Fallback: `[TYPECHECK]` (will still fail until Task 6 — expected).

- [ ] **Step 5: Commit**

```bash
git add PauseCoordinator.swift Tests/LivePaperCoreTests/PauseCoordinatorTests.swift
git commit -m "feat: pause coordinator with transition diffing

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Localization strings

**Files:**
- Modify: `Resources/en.lproj/Localizable.strings`
- Modify: `Resources/zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Produces (localization keys consumed by Tasks 6–7): `menu.batteryPause`, `menu.visibilityPause`, `policy.battery.off/lowBattery/onBattery/followLowPowerMode`, `policy.visibility.off/covered/unfocused`, `reason.lowBattery/asleep/covered/desktopUnfocused/manualAll/manualScreen`, `status.partiallyPaused`, `ui.batteryPause`, `ui.visibilityPause`.

- [ ] **Step 1: Remove obsolete keys and add new ones (English)**

In `Resources/en.lproj/Localizable.strings`, delete these lines if present:
```
"ui.pauseWhenInvisible" = "Battery Saver";
"ui.pauseWhenCovered" = "Pause When Covered";
"ui.pauseWhenCovered.tooltip" = "...";
"ui.pauseUnderThermal" = "Thermal Pause";
"ui.pauseUnderThermal.tooltip" = "...";
"ui.pausedAuto" = "Paused (Battery Saver)";
"menu.autoPause" = "Battery Saver";
"menu.pauseWhenCovered" = "Pause When Covered";
"menu.pauseUnderThermal" = "Thermal Pause";
```
Add (near the other `menu.`/`ui.` entries):
```
"menu.batteryPause" = "Battery Pause";
"menu.visibilityPause" = "Visibility Pause";
"ui.batteryPause" = "Battery pause";
"ui.visibilityPause" = "Visibility pause";
"policy.battery.off" = "Off";
"policy.battery.lowBattery" = "When battery is low";
"policy.battery.onBattery" = "When on battery power";
"policy.battery.followLowPowerMode" = "Follow Low Power Mode";
"policy.visibility.off" = "Off";
"policy.visibility.covered" = "When covered";
"policy.visibility.unfocused" = "When desktop unfocused";
"reason.manualAll" = "Paused by you";
"reason.manualScreen" = "Paused by you";
"reason.lowBattery" = "Low battery";
"reason.asleep" = "Asleep";
"reason.covered" = "Covered";
"reason.desktopUnfocused" = "Desktop not focused";
"status.partiallyPaused" = "Partially paused";
```

- [ ] **Step 2: Mirror in Simplified Chinese**

In `Resources/zh-Hans.lproj/Localizable.strings`, delete the corresponding obsolete keys (`ui.pauseWhenInvisible`, `ui.pauseWhenCovered`(+tooltip), `ui.pauseUnderThermal`(+tooltip), `ui.pausedAuto`, `menu.autoPause`, `menu.pauseWhenCovered`, `menu.pauseUnderThermal`) and add:
```
"menu.batteryPause" = "电量暂停";
"menu.visibilityPause" = "可见性暂停";
"ui.batteryPause" = "电量暂停";
"ui.visibilityPause" = "可见性暂停";
"policy.battery.off" = "关闭";
"policy.battery.lowBattery" = "电量低时";
"policy.battery.onBattery" = "使用电池时";
"policy.battery.followLowPowerMode" = "跟随低电量模式";
"policy.visibility.off" = "关闭";
"policy.visibility.covered" = "被遮挡时";
"policy.visibility.unfocused" = "桌面未聚焦时";
"reason.manualAll" = "已手动暂停";
"reason.manualScreen" = "已手动暂停";
"reason.lowBattery" = "电量低";
"reason.asleep" = "已休眠";
"reason.covered" = "被遮挡";
"reason.desktopUnfocused" = "桌面未聚焦";
"status.partiallyPaused" = "部分暂停";
```

- [ ] **Step 3: Verify the files parse**

Run:
```bash
plutil -lint Resources/en.lproj/Localizable.strings Resources/zh-Hans.lproj/Localizable.strings
```
Expected: both report `OK`.

- [ ] **Step 4: Commit**

```bash
git add Resources/en.lproj/Localizable.strings Resources/zh-Hans.lproj/Localizable.strings
git commit -m "i18n: pause-policy strings, remove thermal/legacy strings

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: WallpaperManager rework (core integration)

**Files:**
- Modify: `WallpaperManager.swift`
- Modify: `build.sh` (add three new source files to the `swiftc` compile list)

**Interfaces:**
- Consumes: `PauseInputs`, `PauseEvaluator`, `PlaybackSummary` (Task 3); `PauseCoordinator`, `ScreenPlaybackState`, `ScreenPlaybackControl` (Task 4); `SettingsManager.batteryPausePolicy/visibilityPausePolicy/migratePausePoliciesIfNeeded` (Task 2).
- Produces (consumed by Tasks 7–8): keeps `pause()`, `resume()`, `pauseScreen(_:)`, `resumeScreen(_:)`, `isScreenPaused(_:) -> Bool`, `isActive`, `var isPaused: Bool` (now `manualAllPaused`). Adds `var statusSummary: PlaybackSummary`, `func reasons(for screen: NSScreen) -> Set<PauseReason>`, `func onPausePolicyChanged()`. Removes `playbackStatus`, `checkPlaybackState()`, `applyOcclusionPolicyChange()`, `isPausedInternally`, `handleVisibilityChange(...)` (public surface), `shouldPauseForThermal()`.

- [ ] **Step 1: Add new files to `build.sh`**

In `build.sh`, in the `swiftc` file list, add the three new files (after `WallpaperManager.swift`):
```
    ScreenPlayer.swift \
    WallpaperManager.swift \
    PausePolicy.swift \
    PauseEvaluator.swift \
    PauseCoordinator.swift \
    MainWindowController.swift \
```
(Insert the three `\`-terminated lines; keep the rest of the list unchanged.)

- [ ] **Step 2: Replace pause state + remove thermal in `WallpaperManager.swift`**

Replace the stored-state block. Change:
```swift
    var isPaused: Bool = false
    private var keepVisibleTimer: Timer?
    private var batteryCheckTimer: Timer?
    private let keepVisibleInterval: TimeInterval = 0.75
    private let lowBatteryPauseThreshold = 20
    private var pausedScreens: Set<String> = []
    /// Screens whose wallpaper window is currently fully covered by other windows.
    /// Tracked continuously; only acted upon when `pauseWhenOccluded` is enabled.
    private var occludedScreens: Set<String> = []
```
to:
```swift
    // Raw pause INPUTS (never derived flags). Playback state is always
    // recomputed from these via reconcile().
    private var manualAllPaused = false
    private var manualPausedScreens: Set<String> = []
    private var occludedScreens: Set<String> = []
    private var systemAsleep = false

    private let coordinator = PauseCoordinator()

    private var keepVisibleTimer: Timer?
    private var batteryCheckTimer: Timer?
    private let keepVisibleInterval: TimeInterval = 0.75

    /// Global manual-pause state (kept for callers/UI).
    var isPaused: Bool { manualAllPaused }
```

Delete the `enum PlaybackStatus { ... }` and the `var playbackStatus: PlaybackStatus { ... }` computed property entirely (replaced by `statusSummary`).

- [ ] **Step 3: Rewire notifications to `reconcile()` and add sleep tracking**

In `init()`, replace the four `#selector(checkPlaybackState)` observer registrations (activeSpace, didActivateApplication, didWake, screensDidWake) so their selector is `#selector(reconcileFromNotification)`. Replace the two `#selector(handleSleep)` registrations' selector with `#selector(handleSleepNotification)`. Delete the thermal observer block (the one registering `ProcessInfo.thermalStateDidChangeNotification`). Add a Low Power Mode observer:
```swift
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reconcileFromNotification),
            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
```
Replace `handleSleep`, `handleScreenLocked`, `checkPlaybackState`, `appBecameActive`, `handleVisibilityChange`, `applyOcclusionPolicyChange` with:
```swift
    @objc private func reconcileFromNotification() { reconcile() }

    @objc private func handleSleepNotification() {
        systemAsleep = true
        reconcile()
    }

    @objc private func handleWakeNotification() {
        systemAsleep = false
        reconcile()
    }

    @objc private func handleScreenLocked(_ note: Notification) {
        systemAsleep = true
        reconcile()
    }
```
Update the wake observers (`didWakeNotification`, `screensDidWakeNotification`) to use `#selector(handleWakeNotification)` (they must clear `systemAsleep`). Keep the lock/screensaver distributed-notification observers pointed at `#selector(handleScreenLocked(_:))`. Add matching unlock/screensaver-stop observers so sleep clears:
```swift
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleWakeNotification),
            name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleWakeNotification),
            name: Notification.Name("com.apple.screensaver.didstop"), object: nil)
```

- [ ] **Step 4: Add the ScreenPlayer occlusion callback filter + reconcile**

Find where `createOrUpdatePlayer` sets `player.onVisibilityChange` and replace that closure body so occlusion input is ignored for screens the app hides itself, then reconciles:
```swift
            player.onVisibilityChange = { [weak self] visible in
                guard let self else { return }
                // Ignore occlusion reports for screens we've hidden ourselves
                // (an ordered-out window reports "not visible" — that's us).
                if self.manualAllPaused || self.manualPausedScreens.contains(id) { return }
                if visible { self.occludedScreens.remove(id) } else { self.occludedScreens.insert(id) }
                self.reconcile()
            }
```
Delete the old post-creation seeding block that referenced `player.isVisibleOnScreen` / `shouldPauseScreen(id)` (occlusion is now seeded lazily by the first callback; initial pause is handled by the reconcile at end of Step 6).

- [ ] **Step 5: Replace the pause/resume public API + helpers**

Replace `shouldPauseScreen`, `pause`, `resume`, `pauseScreen`, `resumeScreen`, `isScreenPaused`, `resumeAll`, `pauseAll`, `showAll`-driven logic, and the scattered `shouldPauseScreen(...)` call sites in the rotation/create paths. Concretely:

Delete `shouldPauseScreen(_:)`, `resumePlayerAligned` **callers that gate on shouldPauseScreen**, `pauseAll()`, `resumeAll()`, the old `pause()/resume()/pauseScreen/resumeScreen`, and `shouldPauseForThermal()` / `currentBatterySnapshot`'s only-thermal usage (keep `currentBatterySnapshot`). Add:
```swift
    // MARK: - Public pause API (mutate inputs, then reconcile)

    func pause()  { manualAllPaused = true;  reconcile() }
    func resume() { manualAllPaused = false; reconcile() }

    func pauseScreen(_ screen: NSScreen) {
        manualPausedScreens.insert(SettingsManager.screenIdentifier(screen)); reconcile()
    }
    func resumeScreen(_ screen: NSScreen) {
        manualPausedScreens.remove(SettingsManager.screenIdentifier(screen)); reconcile()
    }
    func isScreenPaused(_ screen: NSScreen) -> Bool {
        manualPausedScreens.contains(SettingsManager.screenIdentifier(screen))
    }

    /// Called by the UI when a pause policy setting changes.
    func onPausePolicyChanged() { reconcile() }

    // MARK: - Reconcile (single application path)

    private func currentPowerState() -> PowerState {
        let snap = currentBatterySnapshot()
        return PowerState(
            batteryLevel: snap?.level,
            isCharging: snap?.isCharging ?? true,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    private func desktopIsFrontmost() -> Bool {
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let bundle else { return true } // desktop click / unknown → treat as desktop
        let selfBundle = Bundle.main.bundleIdentifier
        return bundle == "com.apple.finder" || bundle == "com.apple.dock" || bundle == selfBundle
    }

    private func currentPauseInputs() -> PauseInputs {
        PauseInputs(
            screenIDs: Array(players.keys),
            manualAll: manualAllPaused,
            manualScreens: manualPausedScreens,
            systemAsleep: systemAsleep,
            power: currentPowerState(),
            batteryPolicy: SettingsManager.shared.batteryPausePolicy,
            visibilityPolicy: SettingsManager.shared.visibilityPausePolicy,
            occludedScreens: occludedScreens,
            desktopFrontmost: desktopIsFrontmost())
    }

    func reconcile() {
        guard isActive else { coordinator.reset(); return }
        let reasonsByScreen = PauseEvaluator.reasonsByScreen(currentPauseInputs())
        let changed = coordinator.reconcile(reasonsByScreen: reasonsByScreen, control: self)
        if changed {
            NotificationCenter.default.post(name: WallpaperManager.playbackStateDidChangeNotification, object: nil)
        }
    }

    // MARK: - Status (for UI)

    var statusSummary: PlaybackSummary {
        PauseEvaluator.summarize(PauseEvaluator.reasonsByScreen(currentPauseInputs()), isActive: isActive)
    }

    func reasons(for screen: NSScreen) -> Set<PauseReason> {
        PauseEvaluator.reasons(for: SettingsManager.screenIdentifier(screen), currentPauseInputs())
    }
```

- [ ] **Step 6: Implement `ScreenPlaybackControl` and fix the create/rotation gates**

Add an extension conforming to the protocol:
```swift
extension WallpaperManager: ScreenPlaybackControl {
    func apply(_ state: ScreenPlaybackState, to screenID: String) {
        guard let player = players[screenID] else { return }
        switch state {
        case .playing:
            player.window?.orderBack(nil)
            player.window?.orderFrontRegardless()
            resumePlayerAligned(screenID) // preserves sync-on-resume
        case .frozen:
            player.window?.orderBack(nil)
            player.pausePlayback()
        case .hidden:
            player.pausePlayback()
            player.window?.orderOut(nil)
        }
    }
}
```
In every media-load / rotation path that previously read `if isPaused || isPausedInternally ...` or `if shouldPauseScreen(sid) { player.pausePlayback() }` (in `setFolder`, the sync-group rotation loop, `selectPlaylistItem`, `nextWallpaper(forScreenID:)`, and the `setWallpaper` asyncAfter block), **delete those inline pause blocks** and instead call `reconcile()` once after the player(s) are created/updated. The coordinator will pause/hide the freshly created player if its reasons are non-empty. Keep `resumePlayerAligned` and `syncGroupLeaderTime` unchanged.

`stopAll()` / `stopWallpaper(for:)` / screen-removal: replace `pausedScreens` references with `manualPausedScreens`, keep the `occludedScreens.remove(...)`/`removeAll()` cleanups, and call `coordinator.reset()` in `stopAll()` and `coordinator.reset()`-equivalent forgetting is handled automatically by the next `reconcile()` for per-screen stop. Ensure `manualAllPaused = false` in `stopAll()`.

`startKeepVisibleTimer`'s `showAll()`: change `showAll()` to only order back windows whose coordinator state is not `.hidden`:
```swift
    private func showAll() {
        players.forEach { id, player in
            if coordinator.applied[id] == .hidden { return }
            player.window?.orderBack(nil)
        }
    }
```

- [ ] **Step 7: Run migration at startup**

Ensure `SettingsManager.shared.migratePausePoliciesIfNeeded()` is called once at launch. Add it in `AppDelegate.applicationDidFinishLaunching` immediately after `wallpaperManager = WallpaperManager()` (this line will be added in Task 7; note it here as a cross-task dependency). For now, verify no compile references to removed symbols remain.

- [ ] **Step 8: Typecheck**

Run `[TYPECHECK]`.
Expected: no output, exit 0. (AppDelegate/MainWindowController still reference old symbols — this typecheck will FAIL until Tasks 7–8 are done. That is expected; if you are executing strictly task-by-task, run `swiftc -typecheck` on just the core set to confirm WallpaperManager itself is consistent:)
```bash
swiftc -typecheck -target "$(uname -m)-apple-macos12.0" \
  Screen_Config.swift SettingsManager.swift MediaType.swift PlaylistBuilder.swift \
  Localization.swift PerformanceMonitor.swift ScreenPlayer.swift WallpaperManager.swift \
  PausePolicy.swift PauseEvaluator.swift PauseCoordinator.swift \
  -framework Cocoa -framework AVKit -framework AVFoundation -framework IOKit
```
Expected: fails only on AppDelegate/MainWindow symbols if any are referenced from WallpaperManager (there should be none) — otherwise passes.

- [ ] **Step 9: Commit**

```bash
git add WallpaperManager.swift build.sh
git commit -m "refactor: WallpaperManager derive-and-reconcile pause model

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: AppDelegate menu + status

**Files:**
- Modify: `AppDelegate.swift`

**Interfaces:**
- Consumes: `WallpaperManager.statusSummary`, `.reasons(for:)`, `.pause()/.resume()`, `SettingsManager.batteryPausePolicy/visibilityPausePolicy/migratePausePoliciesIfNeeded`, localization keys from Task 5.
- Produces: menu items `batteryPauseItem` (submenu), `visibilityPauseItem` (submenu); handlers `setBatteryPolicy(_:)`, `setVisibilityPolicy(_:)`.

- [ ] **Step 1: Run migration at launch**

In `applicationDidFinishLaunching`, immediately after `wallpaperManager = WallpaperManager()`, add:
```swift
        SettingsManager.shared.migratePausePoliciesIfNeeded()
```

- [ ] **Step 2: Replace the three old menu items with two submenus**

Delete the property declarations `autoPauseItem`, `pauseWhenCoveredItem`, `thermalPauseItem` and add:
```swift
    var batteryPauseItem: NSMenuItem!
    var batteryPauseMenu: NSMenu!
    var visibilityPauseItem: NSMenuItem!
    var visibilityPauseMenu: NSMenu!
```
In `setupMenu` (where the three items were added), delete the three `menu.addItem(...)` blocks for auto/covered/thermal and add:
```swift
        batteryPauseMenu = NSMenu(title: "menu.batteryPause".localized)
        batteryPauseItem = NSMenuItem(title: "menu.batteryPause".localized, action: nil, keyEquivalent: "")
        batteryPauseItem.submenu = batteryPauseMenu
        menu.addItem(batteryPauseItem)

        visibilityPauseMenu = NSMenu(title: "menu.visibilityPause".localized)
        visibilityPauseItem = NSMenuItem(title: "menu.visibilityPause".localized, action: nil, keyEquivalent: "")
        visibilityPauseItem.submenu = visibilityPauseMenu
        menu.addItem(visibilityPauseItem)
```

- [ ] **Step 3: Add rebuild + handlers; delete old handlers**

Delete `toggleAutoPause`, `updateAutoPauseItem`, `togglePauseWhenCovered`, `updatePauseWhenCoveredItem`, `togglePauseUnderThermal`, `updateThermalPauseItem`. Add:
```swift
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
```

- [ ] **Step 4: Update `menuWillOpen` and status label**

In `menuWillOpen`, replace `updateAutoPauseItem()` / `updatePauseWhenCoveredItem()` / `updateThermalPauseItem()` calls with:
```swift
        rebuildBatteryPauseMenu()
        rebuildVisibilityPauseMenu()
        updateStatusLine()
```
Rename the old status method (was inside `updateAutoPauseItem`). Create `updateStatusLine()` replacing the old `switch wallpaperManager.playbackStatus` with:
```swift
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
```

- [ ] **Step 5: Add per-screen reason suffix in the pause submenu**

In `rebuildPauseMenu`, where each per-screen item's `suffix` is built, replace the manual `isPaused ? resume : pause` suffix with the actual reason when paused:
```swift
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
```

- [ ] **Step 6: Typecheck + build**

Run `[TYPECHECK]`. Expected: no output, exit 0 (once MainWindow is not referencing removed symbols — if MainWindow still uses old members, this fails until Task 8; run Task 8 then re-run).

Then: `./build.sh` — Expected: `Done! App: build/LivePaper.app`.

- [ ] **Step 7: Commit**

```bash
git add AppDelegate.swift
git commit -m "feat: battery/visibility pause submenus + reason-aware status

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: MainWindowController pop-up controls

**Files:**
- Modify: `MainWindowController.swift`

**Interfaces:**
- Consumes: `SettingsManager.batteryPausePolicy/visibilityPausePolicy`, `WallpaperManager.onPausePolicyChanged`, localization keys from Task 5.
- Produces: none (leaf UI).

- [ ] **Step 1: Remove the three old checkboxes**

Delete the property declarations `pauseSwitch`, `pauseCoveredSwitch`, `thermalSwitch`, their `NSButton(checkboxWithTitle:...)` setup blocks, their `@objc func ...Changed` handlers (`pauseSwitchChanged`, `pauseCoveredSwitchChanged`, `thermalSwitchChanged`), and their `.state = ...` lines in `updateUI`. Also remove any use of `wallpaperManager.isPausedInternally` (the auto-paused hint around the status area) — replace that hint logic with `wallpaperManager.statusSummary` if a hint is shown, else delete it.

- [ ] **Step 2: Add two labeled pop-up buttons**

Add properties:
```swift
    private var batteryPolicyPopup: NSPopUpButton!
    private var visibilityPolicyPopup: NSPopUpButton!
```
In the settings layout (where the old checkboxes lived, top rows), add:
```swift
        let batteryLabel = NSTextField(labelWithString: "ui.batteryPause".localized + ":")
        batteryLabel.font = NSFont.systemFont(ofSize: 12)
        batteryLabel.frame = NSRect(x: 0, y: 156, width: 95, height: 20)
        settings.addSubview(batteryLabel)

        batteryPolicyPopup = NSPopUpButton(frame: NSRect(x: 98, y: 152, width: 170, height: 25), pullsDown: false)
        batteryPolicyPopup.addItems(withTitles: [
            "policy.battery.off".localized,
            "policy.battery.lowBattery".localized,
            "policy.battery.onBattery".localized,
            "policy.battery.followLowPowerMode".localized,
        ])
        batteryPolicyPopup.target = self
        batteryPolicyPopup.action = #selector(batteryPolicyChanged(_:))
        settings.addSubview(batteryPolicyPopup)

        let visibilityLabel = NSTextField(labelWithString: "ui.visibilityPause".localized + ":")
        visibilityLabel.font = NSFont.systemFont(ofSize: 12)
        visibilityLabel.frame = NSRect(x: 0, y: 128, width: 95, height: 20)
        settings.addSubview(visibilityLabel)

        visibilityPolicyPopup = NSPopUpButton(frame: NSRect(x: 98, y: 124, width: 170, height: 25), pullsDown: false)
        visibilityPolicyPopup.addItems(withTitles: [
            "policy.visibility.off".localized,
            "policy.visibility.covered".localized,
            "policy.visibility.unfocused".localized,
        ])
        visibilityPolicyPopup.target = self
        visibilityPolicyPopup.action = #selector(visibilityPolicyChanged(_:))
        settings.addSubview(visibilityPolicyPopup)
```
(If the removed checkboxes had shifted `syncDesktopSwitch` to `x: 230, y: 130`, restore it to `x: 0, y: 100, width: 380` and shift the remaining rows down consistently so nothing overlaps the two new pop-up rows at y 152/124. Verify visually in Task 9's launch.)

- [ ] **Step 3: Add handlers + selection sync**

Add:
```swift
    @objc func batteryPolicyChanged(_ sender: NSPopUpButton) {
        let all = BatteryPausePolicy.allCases
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < all.count else { return }
        SettingsManager.shared.batteryPausePolicy = all[sender.indexOfSelectedItem]
        wallpaperManager.onPausePolicyChanged()
    }

    @objc func visibilityPolicyChanged(_ sender: NSPopUpButton) {
        let all = VisibilityPausePolicy.allCases
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < all.count else { return }
        SettingsManager.shared.visibilityPausePolicy = all[sender.indexOfSelectedItem]
        wallpaperManager.onPausePolicyChanged()
    }
```
> Note: `addItems` order MUST match `BatteryPausePolicy.allCases` / `VisibilityPausePolicy.allCases` declaration order (off, lowBattery, onBattery, followLowPowerMode) / (off, covered, unfocused). The enum cases are declared in exactly that order in Task 1.

In `updateUI`, add:
```swift
        batteryPolicyPopup.selectItem(at: BatteryPausePolicy.allCases.firstIndex(of: SettingsManager.shared.batteryPausePolicy) ?? 0)
        visibilityPolicyPopup.selectItem(at: VisibilityPausePolicy.allCases.firstIndex(of: SettingsManager.shared.visibilityPausePolicy) ?? 0)
```

- [ ] **Step 4: Typecheck + build**

Run `[TYPECHECK]`. Expected: no output, exit 0.
Run `./build.sh`. Expected: `Done! App: build/LivePaper.app`.

- [ ] **Step 5: Commit**

```bash
git add MainWindowController.swift
git commit -m "feat: pause-policy pop-up controls in settings window

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Integration verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite (if Xcode available)**

Run: `swift test`
Expected: all tests pass, including `PausePolicyTests`, `PauseEvaluatorTests`, `PauseCoordinatorTests`, and the new `SettingsManagerTests` migration cases.
If XCTest is unavailable (CLT-only), record that and rely on `[TYPECHECK]` (exit 0) + the manual smoke below.

- [ ] **Step 2: Build and launch**

```bash
./build.sh && pkill -x LivePaper 2>/dev/null; sleep 1; open build/LivePaper.app && sleep 2 && pgrep -x LivePaper && echo "launched OK"
```
Expected: `Done! App: build/LivePaper.app` then `launched OK`.

- [ ] **Step 3: Manual smoke checklist**

Verify in the running app (set a video wallpaper first):
- Menu bar shows **Battery Pause ▸** and **Visibility Pause ▸** submenus, each with a checkmark on the current policy; no "Battery Saver" / "Pause When Covered" / "Thermal Pause" items remain.
- Set Visibility Pause → **When covered**; fully cover the display with a window → that screen's wallpaper freezes; uncover → resumes (synced screens realign).
- Set Visibility Pause → **When desktop unfocused**; click another app → wallpaper freezes; click the desktop → resumes.
- Set Battery Pause → **On battery power** (on a laptop, unplug) → freezes; replug → resumes. On a desktop Mac, this option is a no-op (no battery) — confirm it does not pause.
- Toggle global Pause → wallpaper hides (static desktop shows); Resume → returns.
- Status line reflects the dominant reason (e.g. "…(Low battery)"), and shows "Partially paused" when one of two screens is covered.
- Settings window: two pop-ups reflect and change the policies; changes take effect immediately.

- [ ] **Step 4: Confirm no leftover symbols**

```bash
grep -rn "pauseWhenInvisible\|pauseWhenOccluded\|pauseUnderThermal\|isPausedInternally\|shouldPauseForThermal\|playbackStatus\|thermalPauseItem\|pauseWhenCoveredItem\|autoPauseItem" --include="*.swift" .
```
Expected: no matches (empty output).

- [ ] **Step 5: Final commit (if any verification tweaks were made)**

```bash
git add -A
git commit -m "test: verify pause/power model rework end-to-end

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

- **Spec coverage:** reasons model (Tasks 1,3,4,6), battery 4-mode policy (Tasks 1–3, 7–8), visibility 3-mode incl. per-screen `covered` + global `unfocused` (Tasks 1,3,6), thermal removal (Tasks 2,5,6,7,8 + Task 9 grep), migration (Task 2), hide-vs-freeze (Tasks 1,4,6), occlusion-pollution fix (Task 6 Step 4), sync-on-resume preserved (Task 6 `resumePlayerAligned` in `.playing`), status summary + per-screen detail (Tasks 3,7), UI menu + popups + localization (Tasks 5,7,8), tests (Tasks 1–4,9). All spec sections map to a task.
- **Type consistency:** `PauseInputs`, `PowerState`, `PauseReason`, `ScreenPlaybackState`, `PlaybackSummary`, `PauseEvaluator.reasons/reasonsByScreen/summarize/batteryConditionMet`, `PauseCoordinator.reconcile/desiredState/reset`, `SettingsManager.batteryPausePolicy/visibilityPausePolicy/migratePausePoliciesIfNeeded`, `WallpaperManager.statusSummary/reasons(for:)/onPausePolicyChanged` — names are identical across defining and consuming tasks.
- **Known cross-task typecheck ordering:** Tasks 2/3/4/6 individually leave the whole app un-typecheckable until Tasks 7–8 remove old call sites; each such step flags this explicitly and points to the core-only typecheck or the later task. The suite is green again at Task 8 Step 4 and Task 9.
