# Changelog

All notable changes to LivePaper are documented here.

## v1.1.0 — 2026-07-22

### Added
- Reworked the pause/power system into a per-screen **pause-reasons** engine: a
  screen plays unless it has an active reason to pause, and every event funnels
  through one reconcile step (no more scattered/conflicting flags).
- **Battery Pause** policy: *Off* / *When battery is low* / *When on battery power* /
  *Follow Low Power Mode*.
- **Configurable low-battery threshold** (5–95%, default 20%) for the "When battery
  is low" policy — settable via a stepper in the settings window.
- **Visibility Pause** policy: *Off* / *When covered* (fully occluded) / *When desktop
  unfocused* (another app frontmost). Replaces the previous single fixed behavior
  with a choice.
- Status readout and the per-screen pause submenu now name *why* each screen is
  paused (Low battery, Covered, Desktop not focused, Asleep, Paused by you).
- Synced screens re-align to the same video frame when a paused screen resumes.

### Changed
- The single "Battery Saver" toggle is replaced by the **Battery Pause** and
  **Visibility Pause** pop-ups (settings window) and status-bar submenus.
- Reorganized the settings window into aligned Power and Rotation groups.
- **Idle-energy optimization:** window ordering is now event-driven with an ~8s
  backstop timer instead of a 0.75s poll, and all repeating timers are coalesced
  (battery poll 60s → 120s). Far fewer CPU wake-ups while the Mac is awake and
  idle; no behavior change and no effect on sleep.

### Removed
- Thermal-pause toggle — measured net-neutral in practice, dropped to keep the
  model simple.
- A high-fps render cap was trialed and reverted after measurement showed no
  CPU or GPU benefit on Apple Silicon (hardware decode + display-rate
  compositing already make the extra frames cheap).

### Fixed
- Crash when toggling macOS Low Power Mode (the pause reconcile now always runs
  on the main thread; power-state notifications arrive on a background thread).
- The settings-window preview no longer mislabels a playing screen as
  auto-paused during multi-monitor partial-pause states.

## v1.0.1

- Initial LivePaper release (fork of SakuraWallpaper): video/image wallpapers,
  per-screen rotation, synchronized linking, system desktop sync, low-battery
  auto-pause, multi-display support.
