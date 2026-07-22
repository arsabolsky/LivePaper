# Footprint Optimization — Design

**Date:** 2026-07-22
**Status:** Approved (design)
**Branch:** `performance-tweaks`
**Component:** `WallpaperManager`, `ScreenPlayer`

## Goal

Shrink LivePaper's runtime footprint — idle CPU/energy, RAM pressure, and GPU
load while playing — **without removing or breaking any feature**. These are
behavioral tunings, not feature cuts.

Targets chosen by the user: idle CPU/energy, RAM, and GPU-while-playing.

## Baseline (BEFORE)

Measured on Apple Silicon, main display 60Hz, with a generated 1920x1080 **120fps**
H.264 clip (~9.4MB, looping) set as the wallpaper on all screens, playing and
unobscured:

- **CPU: ~8.0% average** (range 6.2–9.5%). The clip is 120fps on a 60Hz display,
  so roughly half the decoded frames are never shown — exactly the waste the FPS
  cap targets.
- **Memory (RSS): ~41 MB**, stable.
- **Idle wake-ups:** noisy under `top`; the 0.75s keep-visible timer is a
  constant contributor (~1.3 wake-ups/sec on its own, independent of decode).

Measurement method (reproducible, used again for the AFTER pass) is in
**Verification** below.

## Scope

**In scope (three optimizations):**
1. Event-driven window ordering (replace the 0.75s keep-visible poll).
2. Conditional playback FPS cap for high-fps sources.
3. Timer coalescing via `.tolerance` on all repeating timers.

**Deferred (documented, NOT built here):** Free a screen's video decode buffers
after it has been paused/hidden for a while, rebuilding on resume. This is a real
RAM lever the user explicitly parked for later — it costs a brief reload/seek on
resume and needs its own design.

**Explicitly out of scope:** launch time and binary/disk size (binary is already
~1 MB).

## 1. Event-driven window ordering

**Problem.** `keepVisibleTimer` fires every 0.75s for the entire time a wallpaper
is active and calls `showAll()` → `orderBack(nil)` on every non-hidden window,
whether or not anything changed. That is ~1.3 wake-ups/sec, 24/7, purely to
re-assert z-order in case macOS reordered the desktop-level windows.

**Design (Approach A — event-driven + slow tolerant safety net).**
- Extract the current `showAll()` body into `reassertWindowOrder()`: for each
  player, if `coordinator.applied[id] != .hidden`, `window?.orderBack(nil)`.
  (This is exactly today's `showAll()` behavior; `showAll()` becomes a call to it
  or is renamed.)
- Call `reassertWindowOrder()` at the tail of `reconcile()`. `reconcile()` already
  runs on every ordering-relevant event — active-space change, app activation,
  wake, screen-parameter change, occlusion change — so ordering is re-asserted
  exactly when the system might have disturbed it. `orderBack` on a window already
  at the right level is a near-noop, so this adds negligible cost.
- **Remove** the 0.75s `keepVisibleTimer`. Replace it with a single **backstop
  timer at 8s with `.tolerance = 2s`** whose handler calls
  `reassertWindowOrder()`. This catches any reorder that fired no observed event,
  keeping the z-order glitch risk near-zero.
- Timer lifecycle mirrors the current one: start when a wallpaper becomes active
  (the existing `startKeepVisibleTimer()` call sites), stop in `stopAll()` /
  when `players.isEmpty` / `deinit` (rename to `startOrderBackstopTimer()` /
  `stopOrderBackstopTimer()` for clarity).

**Expected effect.** Ordering wake-ups drop from ~1.3/sec to ~0.12/sec and
coalesce with other timers. No behavior change visible to the user.

## 2. Conditional playback FPS cap

**Problem.** A clip whose source frame rate exceeds the display refresh is decoded
and pushed through the render pipeline at the full source rate; the extra frames
are never presented. On the 120fps-on-60Hz baseline that is ~half the work wasted.

**Design.**
- In `ScreenPlayer.setupVideoPlayer`, after creating the `AVURLAsset`, load the
  video track's `nominalFrameRate` (load the track/property asynchronously to
  avoid a main-thread hitch; apply the composition before/at play).
- Compute `target = min(screenRefreshHz, 60)` where `screenRefreshHz` comes from
  `screen.maximumFramesPerSecond` (available macOS 12+; fall back to 60 if 0).
- **Only if `sourceFPS > target + 1`**, build an
  `AVMutableVideoComposition(propertiesOf: asset)` (a passthrough composition),
  set `frameDuration = CMTime(value: 1, timescale: CMTimeScale(target))`, and
  assign it to the `AVPlayerItem.videoComposition`. Otherwise leave
  `videoComposition` nil — normal 24/30/60fps clips get **zero** added overhead.

**Honest caveats (recorded so the AFTER measurement judges them):**
- The composition reduces the *render / color-convert / GPU-upload* cadence — the
  dominant energy cost — to `target`. Actual *decode* savings depend on the codec
  and GOP structure; a passthrough composition does not guarantee the decoder
  skips frames.
- A passthrough composition adds a compositing pass, which is why this is **gated**
  to `sourceFPS > target`: for a clip already at or below target it would be pure
  overhead, so we never attach it there.
- If the AFTER measurement shows the composition is net-negative even for high-fps
  sources on this hardware, we drop this optimization rather than ship a
  regression. The gate makes that a clean revert (one code path).

## 3. Timer coalescing

Add `.tolerance` to every repeating `Timer` so macOS batches their wake-ups with
other system timers:
- Sync-group rotation timer and per-screen rotation timers: `tolerance =
  interval * 0.1`.
- Battery poll: raise interval **60s → 120s** and set `tolerance = 15`. Battery
  *level* changes slowly and the instantaneous events (Low Power Mode, AC
  connect/disconnect) already arrive via `NSProcessInfoPowerStateDidChange`, so a
  2-minute level poll is plenty responsive.
- Order-backstop timer: `8s ± 2s` (from §1).

Pure idle-energy win, no behavior change.

## Architecture / boundaries

All three changes are internal to two files and change no public API, no
settings, no localization, and no persisted data:
- `WallpaperManager`: timer lifecycle + `reassertWindowOrder()` + `.tolerance`.
- `ScreenPlayer`: FPS-cap composition inside video setup.

The reasons/coordinator model, sync-on-resume, and every pause policy are
untouched.

## Verification

**Reproducible measurement harness** (temporary, not committed):
1. Add to `applicationDidFinishLaunching`, after `restoreAllScreens()`:
   ```swift
   if let p = ProcessInfo.processInfo.environment["LIVEPAPER_TEST_VIDEO"] {
       wallpaperManager.setWallpaper(url: URL(fileURLWithPath: p)) // PERF-HARNESS
   }
   ```
2. Generate the clip once:
   ```bash
   ffmpeg -y -f lavfi -i testsrc2=size=1920x1080:rate=120 -t 8 \
     -c:v libx264 -preset veryfast -pix_fmt yuv420p test1080p120.mp4
   ```
3. Launch and sample:
   ```bash
   LIVEPAPER_TEST_VIDEO=/path/test1080p120.mp4 \
     build/LivePaper.app/Contents/MacOS/LivePaper &
   top -l 13 -s 2 -pid "$(pgrep -x LivePaper)" -stats pid,cpu,mem,idlew
   ```
   Discard the warmup sample; average CPU over the rest.
4. Remove the harness hook before committing.

**Pass criteria:**
- **CPU (playing, 120fps clip):** measurably lower than the ~8.0% baseline (FPS
  cap is expected to be the driver). If not lower, §2 is reverted.
- **Idle wake-ups:** lower than baseline in a resting state (§1 + §3). Best
  observed with the wallpaper paused/covered so decode is not the dominant term.
- **RAM:** no regression vs. ~41 MB.
- **No feature regression:** wallpaper still plays, rotates, syncs, and obeys all
  pause policies; the `swift test` suite (on a machine with Xcode) still passes.

`powermetrics` (true energy/GPU counters) requires `sudo` and is a **manual**
check the user runs; the automated proxy is `top` CPU% + `idlew`.

## Out of scope / follow-up

- Free decode buffers when hidden (RAM) — parked by the user; own spec later.
