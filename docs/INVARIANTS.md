# ArcShot Invariants (DO NOT BREAK)

This document lists **hard rules** proven by production bugs and regression tests.
Read this before changing capture, cursor, launcher, or export code.

Related docs:

- `docs/QUALITY_STANDARDS.md` — release bar
- `docs/MANUAL_VERIFICATION.md` — human QA matrix
- `docs/export/PIPELINE.md` — compositor pipeline map

---

## 1. Cursor coordinates (capture → project → preview → export)

### Coordinate convention

| Layer | Origin | Notes |
| --- | --- | --- |
| macOS global mouse (`CGEvent`) | Bottom-left of main display | Used when sampling cursor during recording |
| `RecordingProject.CursorSample` | Normalized 0…1, **bottom-left** (`y=1` = top of content) | Stored in project JSON |
| CIImage / compositor video | Bottom-left | `ArcShotVideoCompositor` converts to top-left only at draw time |
| SwiftUI preview | Top-left | Uses same normalized samples via shared layout helpers |

**Never** flip Y twice. **Never** store AppKit top-left Y in `CursorSample`.

### Mapping rect for window capture (critical)

When normalizing mouse position during recording, use:

```
latestStreamScreenRect ?? selection.contentRect
```

- `SCContentFilter.contentRect` is **not** the same as on-screen window bounds for window picks.
- Typical delta: filter `minY` is ~33pt **above** `SCStreamFrameInfo.screenRect` (title-bar inset).
- Using filter rect alone causes cursor to appear **shifted upward** in preview/export.

Implementation:

- `RecordingCoordinator.cursorMappingRect(for:)`
- `RecordingCoordinator.cursorMappingRect(filterContentRect:streamScreenRect:)` — static, covered by unit tests
- `RecordingWriterSession` / `ScreenStreamFrameMetadata.screenRect` — parse stream attachments every frame

**Do not** use stream buffer-local `(0,0,w,h)` as mapping rect.

### Burn-in

- `SCStreamConfiguration.showsCursor = false` always for product capture.
- Cursor is rendered from recorded samples in preview + `ArcShotVideoCompositor`.

### Tests that must stay green

- `ArcShotTests` — cursor mapping with screenRect offset (`testNormalizedCursorPositionUsesScreenRectWhenOffsetFromFilter` and related)

---

## 2. AVCaptureSession lifecycle (microphone + camera)

Apple throws (and may hang in debug) if you call `startRunning()` **between** `beginConfiguration()` and `commitConfiguration()`.

### Required pattern

```swift
session.beginConfiguration()
// add inputs/outputs, set preset, set delegates
session.commitConfiguration()
session.startRunning()
```

### Files

| File | Role |
| --- | --- |
| `Features/Capture/MicrophoneCapture.swift` | Mic samples → `RecordingWriterSession.appendMicrophoneSample` |
| `Features/Capture/CameraMovieCapture.swift` | Separate `.mov` for PiP / future front-camera workflows |

### Microphone-specific rules

- Configure and `startRunning()` on `MicrophoneCapture`'s **serial queue**, not on MainActor.
- Public API is `async start()` — await from `RecordingCoordinator.startRecording`.
- On failure paths before `commitConfiguration()`, always call `commitConfiguration()` before throwing.

**Regression symptom:** countdown reaches `1`, beach ball, console: `startRunning may not be called between beginConfiguration and commitConfiguration`.

---

## 3. Recording launcher countdown

Product recording starts from **`FloatingRecordingLauncherController`** (`Features/Capture/FloatingRecordingWidget.swift`), not `RecordView`.

### Flow

1. User taps REC on floating bar
2. Full-screen `CountdownOverlay` panel (`RecordingCountdown.seconds`, currently 3)
3. Dismiss overlay → `Task.yield()` → `RecordingCoordinator.startRecording`
4. Mini recording bar appears top-right while `.recording`

### Shared constants

- `RecordingCountdown.seconds` in `CountdownOverlay.swift` — single source for launcher + dev `RecordView`

### Do not

- Call `startRecording` synchronously inside countdown UI update without yielding — blocks launcher SwiftUI body.
- Skip countdown for launcher without explicit product decision (dev `RecordView` may differ).

---

## 4. Export sandbox + temp files

Sandboxed app **cannot** write arbitrary user paths without security-scoped bookmarks.

### Pattern

- Encode to temp file inside app container (`Exporter` + `ExportOutputAccess`)
- Copy to user-selected URL while security-scoped access is active
- `ExportOutputAccess.begin(for:)` / `release()` wrap export session

File: `Features/Export/ExportOutputAccess.swift`

**Regression symptom:** export fails with permission error despite user picking a folder.

---

## 5. Export quality defaults

### Source-resolution presets

- `RecordingProject.ExportPresetID.matchSource60` / `matchSource60Hevc`
- `ExportVideoGeometry.matchSourceRenderSize` — largest aspect-correct size **inside** source pixels (no upscale)
- Bitrate scales with pixel count via `ExportPreset.VideoEncoding.scaledBitrateMbps`

Default for **new projects**: `matchSource60` (see `RecordingProject` factory defaults).

### Capture bitrate

- `RecordingCoordinator.CaptureVideoEncoding.bitrateMbps(for:)` scales from 1080p@22Mbps reference
- Retina window captures (~2992×2144) land ~60–70 Mbps — do not revert to flat 10 Mbps

### Compositor scaling

- Use `CIImage.transformed(by:highQualityDownsample: true)` when downscaling in `ArcShotVideoCompositor`
- Applies to zoom, stage layout content fit, and PiP transforms

### Stage layout vs sharpness

- Default `ExportVisualSettings.stageStyle = .roundedCard` shrinks content (padding + card)
- For maximum sharpness, user selects stage **none (full bleed)** in export UI
- Preview and export share `ArcShotRenderGeometry` — keep them in sync

---

## 6. Preview / export parity

Single rendering truth for export: **`ArcShotVideoCompositor`** + `ArcShotCompositionInstructionBuilder`.

Editor preview must use the same geometry helpers (`EditorLayout.swift`, `ArcShotRenderGeometry`).

When changing either path, update:

- `ArcShotTests` geometry tests
- `ExportSmokeTests` fixture exports

Known preview vs export parity risks are summarized in [`docs/export/PIPELINE.md`](export/PIPELINE.md) § preview/export parity.

---

## 7. UI surfaces (do not confuse)

| Surface | Purpose |
| --- | --- |
| Floating launcher bar | **Primary** user recording UX (⌘⇧L) |
| `RecordView` | Dev/debug capture only — banner says so |
| Main workspace | Editor after stop/finalize |
| SwiftUI Settings scene | Language (`ArcShotApp` → `AppLanguageSettingsView`) |

---

## 8. Change checklist (capture / export)

Before merging PRs that touch these areas:

1. `xcodebuild test -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'`
2. Manual: window capture, cursor at 3 points, preview ≈ export
3. Manual: launcher countdown → record with mic ON
4. Manual: export with `matchSource60`, stage none, verify resolution in QuickTime inspector
5. Update this file if you introduce a **new** invariant

---

## 9. Planned work (not yet invariant rules)

Future areas that may become documented invariants after implementation and tests:

| Area | Summary |
| --- | --- |
| **Export pipeline** | Deeper `Exporter.swift` + compositor structure work |
| **Camera UX** | Today: `CameraMovieCapture` sidecar `.mov`; unified timeline UX TBD |

Track work in [GitHub Issues](https://github.com/mameshivaa/Arc-shot/issues). When a rule is stable, promote it into the numbered sections above and add tests.
