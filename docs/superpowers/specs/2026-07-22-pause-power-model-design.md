# Pause / Power Model Rework — Design

**Date:** 2026-07-22
**Status:** Approved (design)
**Component:** `WallpaperManager`, `SettingsManager`, `ScreenPlayer`, `AppDelegate`, `MainWindowController`, `Localizable.strings`

## Goal

Replace LivePaper's scattered pause/resume logic with a single, coherent
**per-screen "pause reasons"** model that is correct, readable, extensible, and
simpler than what exists today.

### Problems in the current model

- A single `isPausedInternally` boolean is shared across battery, thermal, and
  sleep. When two of those conditions overlap and one clears, the flag can drop
  while another still holds — a conflation bug.
- Global auto-pause (battery/thermal/sleep via `pauseAll`) is implemented
  separately from per-screen auto-pause (occlusion via `occludedScreens`) — two
  mechanisms for the same idea.
- Naming is confusing: the "Battery Saver" toggle is stored under a
  `pause_when_invisible` key.
- `playbackStatus` cannot express *why* something is paused; it only knows
  `.playing / .pausedManual / .pausedAuto`.
- Manual `orderOut` marks a window "occluded" via the occlusion notification,
  polluting `occludedScreens` and causing a transient failure-to-resume.

### Success criteria

- **Correctness:** pause state is always *derived* from raw inputs; overlapping
  conditions can never clobber each other.
- **Clarity:** the reason set *is* the status; the UI renders it directly.
- **Extensibility:** a new pause condition is one enum case + one line in the
  derivation function.
- **Simplicity:** every event funnels into one idempotent `reconcile()`.

## Scope

- **In scope:** the reasons model; two configurable policy settings (battery,
  visibility); migration off the old boolean keys; menu + main-window UI; status
  aggregation; preserving the existing sync-on-resume behavior.
- **Removed:** thermal pause is dropped entirely (setting, `shouldPauseForThermal`,
  thermal notification observer, menu item, checkbox, and localized strings that
  were added earlier this session).
- **Out of scope (separate later spec):** continuous frame-lock sync. This
  rework only preserves the current sync-on-resume hook that frame-lock will
  later extend.

## Core model

```swift
enum PauseReason: Hashable {
    case manualAll         // user paused everything (menu / main window)
    case manualScreen      // user paused this specific screen
    case lowBattery        // battery condition met per BatteryPausePolicy
    case asleep            // system/display asleep, screensaver, or locked (fixed)
    case covered           // this screen fully occluded (VisibilityPausePolicy == .covered)
    case desktopUnfocused  // another app is frontmost (VisibilityPausePolicy == .unfocused)
}
```

Two functions carry the whole mechanism:

```swift
// PURE: given current inputs, why (if at all) is this screen paused?
func pauseReasons(for id: String) -> Set<PauseReason>

// IDEMPOTENT: recompute every screen, diff against what's applied, apply the delta.
func reconcile()
```

### Retained state = raw inputs only (never derived pause flags)

This is what eliminates the `isPausedInternally` conflation class.

- `manualAllPaused: Bool`
- `manualPausedScreens: Set<String>`
- `occludedScreens: Set<String>` — maintained by occlusion notifications
- `systemAsleep: Bool` — toggled by sleep/wake/screensaver/lock notifications

Battery %, charging state, Low Power Mode, and the frontmost application are
read **live** inside `pauseReasons` — never cached as booleans.

### Reason derivation

```swift
func pauseReasons(for id: String) -> Set<PauseReason> {
    var r: Set<PauseReason> = []

    if manualAllPaused { r.insert(.manualAll) }
    if manualPausedScreens.contains(id) { r.insert(.manualScreen) }

    if systemAsleep { r.insert(.asleep) }
    if batteryConditionMet() { r.insert(.lowBattery) }

    switch visibilityPolicy {
    case .off:       break
    case .covered:   if occludedScreens.contains(id) { r.insert(.covered) }
    case .unfocused: if !desktopIsFrontmost() { r.insert(.desktopUnfocused) }
    }
    return r
}
```

- `.covered` is **per-screen**. `.desktopUnfocused` is a **global** reason
  (frontmost app is not per-screen) and therefore pauses all screens.

### reconcile()

Every event — any pause-relevant notification, the battery poll timer, a
settings change, an occlusion change, screen add/remove — calls exactly
`reconcile()`. It:

1. Computes `pauseReasons(for:)` for each active screen.
2. Desired state: `reasons.isEmpty` → play, else pause.
3. Diffs desired vs. an `appliedPauseState: [String: Bool]` map and acts **only
   on transitions** (so a playing screen is never redundantly re-seeked/re-paused
   — important because resume performs a sync-seek).
4. Posts `playbackStateDidChangeNotification` only if something actually changed.

This replaces the scattered `pause()/resume()/pauseAll()/resumeAll()/
checkPlaybackState()/handleVisibilityChange()/applyOcclusionPolicyChange()`.

## Conditions and policy settings

Two new policy enums replace the old `pauseWhenInvisible` /
`pauseWhenOccluded` / `pauseUnderThermalPressure` booleans:

```swift
enum BatteryPausePolicy: String { case off, lowBattery, onBattery, followLowPowerMode }
enum VisibilityPausePolicy: String { case off, covered, unfocused }
```

`batteryConditionMet()`:

| Policy | Condition |
|---|---|
| `.off` | never |
| `.lowBattery` | `!charging && level <= 20` (today's behavior) |
| `.onBattery` | `!charging` (any level) |
| `.followLowPowerMode` | `ProcessInfo.processInfo.isLowPowerModeEnabled` |

`desktopIsFrontmost()`: true when `NSWorkspace.shared.frontmostApplication`'s
bundle id is Finder / Dock / LivePaper itself / nil (desktop click).

**Fixed constants (not user-facing):** `asleep` = sleep/screensaver/lock;
battery low threshold = 20%.

**New inputs to wire (both just call `reconcile()`):**
- `NSProcessInfoPowerStateDidChange` — Low Power Mode changes.
- The existing `didActivateApplication` observer — frontmost-app changes.

## Window behavior: hide vs. freeze

Each reason declares whether it hides the window:

- **Hide** (`orderOut` → reveals the static desktop copy): `manualAll`,
  `manualScreen`. Preserves today's manual-pause behavior.
- **Freeze** (pause `AVPlayer`, leave the window on its last frame):
  `lowBattery`, `asleep`, `covered`, `desktopUnfocused`.
- A screen hides if **any** active reason is a hide-reason.

**Occlusion-pollution fix:** because only manual reasons `orderOut`, and the
occlusion input is **ignored for screens we have hidden ourselves** (an
ordered-out window reporting "not visible" is us, not another window), the
stale-`occludedScreens` transient on manual resume is eliminated.

## Sync-on-resume compatibility

When `reconcile()` transitions a screen paused→playing it calls the existing
`resumePlayerAligned(id)` (aligned seek for synced screens), not a plain resume.
The continuous frame-lock spec will extend this same hook.

## UI and status

### Menu bar

Replaces the current "Battery Saver" / "Pause When Covered" / "Thermal Pause"
items:

- **Battery Pause ▸** — radio items: Off · Low battery · On battery power ·
  Follow Low Power Mode (checkmark on the active policy).
- **Visibility Pause ▸** — radio items: Off · When covered · When desktop
  unfocused.
- Existing global Pause and per-screen Pause submenu unchanged (they drive
  `manualAll` / `manualScreen`).

### Status line (aggregate over all screens)

- All screens playing → "Playing".
- All paused with the same dominant reason → e.g. "Paused — Low battery".
- Screens differ → "Partially paused".
- Label priority (highest wins): `manualAll` > `manualScreen` > `lowBattery` >
  `asleep` > `covered` / `desktopUnfocused`.

### Per-screen detail

The existing per-screen pause submenu shows each screen's current reason as a
suffix (e.g. "Built-in Display — Covered", "Studio Display — Playing").

### Main window

Replace the two checkboxes (Battery Saver, Pause When Covered) with two
`NSPopUpButton`s bound to the two policies; remove the thermal checkbox.
Tooltips explain each mode.

### Localization

Add strings for the two policy labels + their options and the reason names used
in the status, in both `en` and `zh-Hans`. Remove the thermal strings.

## Settings persistence and migration

| Old key (bool) | New key | Type |
|---|---|---|
| `livepaper_pause_when_invisible` ("Battery Saver") | `livepaper_battery_pause_policy` | `BatteryPausePolicy` raw string |
| `livepaper_pause_when_occluded` | `livepaper_visibility_pause_policy` | `VisibilityPausePolicy` raw string |
| `livepaper_pause_under_thermal` | *(deleted, no translation)* | — |

**One-time migration** (runs alongside `runCleanSlateInitIfNeeded`): if a new key
is absent but an old one exists, translate then delete the old key —

- old Battery Saver `true` → `.lowBattery` (preserves behavior), else `.off`.
- old occlusion `true` → `.covered`, else `.off`.
- old thermal key → deleted.

Fresh-install defaults: both policies `.off`.

## Testing

The pure-function design is the correctness payoff:

- **`pauseReasons(for:)`** — table-driven tests over the full input matrix (each
  manual flag × each battery policy × battery state × each visibility policy ×
  occlusion/frontmost × sleep). This is where the correctness guarantee lives.
- **`batteryConditionMet()`** and the aggregate **status-label** function — pure,
  injectable, fully tested.
- **Migration** — old-key combinations → expected new policies.
- **`reconcile()` idempotency** — a fake `ScreenPlayer` that counts
  pause/resume/seek calls proves a second `reconcile()` with unchanged inputs
  does nothing (no redundant seeks).

Follows the existing injectable pattern (`SettingsManager(defaults:)`,
`screenIdentifier(deviceDescription:name:)`); no new NSScreen/AVPlayer coupling
in the tested units.

## Out of scope / follow-up

- **Continuous frame-lock sync** — its own spec, building on the
  `resumePlayerAligned` hook preserved here.
