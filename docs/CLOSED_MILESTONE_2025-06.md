# Closed Milestone — Capture / Export Stabilization (2025-06)

**Status:** ✅ Closed and merged to `main`  
**Merge:** [PR #1](https://github.com/mameshivaa/ArcShot/pull/1) (`e99bb23`)  
**Branch:** `fix/clip-trimming` (deleted after merge)

## What was delivered

| Area | Outcome |
| --- | --- |
| Cursor (window capture) | Normalization uses `SCStreamFrameInfo.screenRect` when it differs from filter `contentRect` |
| Export permissions | Sandboxed writes via `ExportOutputAccess` + container temp → user URL copy |
| Launcher UX | Liquid Glass bar, 3s countdown, settings button, recording pulse |
| Countdown freeze | Fixed `AVCaptureSession` lifecycle (`commitConfiguration` before `startRunning`) |
| Export quality | `matchSource60` default, scaled capture/export bitrates, `highQualityDownsample` |
| Documentation | `docs/INVARIANTS.md` + AGENTS/CLAUDE/CONTRIBUTING/README/HANDOFF updates |
| Tests | `xcodebuild test` — **252/252 passing** at closeout |

## Verification at closeout

```sh
cd ArcShot
xcodebuild test -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'
```

Manual checks documented in `docs/MANUAL_VERIFICATION.md` (launcher countdown + mic, window cursor alignment, matchSource export).

## Rules for future work

Do **not** revert patterns documented in `docs/INVARIANTS.md` without updating tests and that file.

## Explicitly out of scope (delegated — see `docs/NEXT_MILESTONES.md`)

1. Export pipeline structural analysis / rewrite (`Exporter.swift` + compositor)
2. First-class incamera recording UX (today: `CameraMovieCapture` sidecar `.mov`)

## Next assignee entry point

Start with **`docs/NEXT_MILESTONES.md`**.
