# ArcShot Quality Standards

## Goal

ArcShot should become an open-source, local-first demo-video recorder for macOS:

- Native Swift/SwiftUI, ScreenCaptureKit, AVFoundation, and Metal/Core Image.
- Local-first by default.
- Free and open source.
- Good enough that developers star it because it is useful, technically credible, and easy to try.

The quality bar is not "can record a screen." The bar is "can produce a polished product demo without fighting the app."

## Release Bar

A release is not ready unless all P0 criteria are true.

### P0: Must Pass

- The app builds from a clean checkout with the documented Xcode version.
- `xcodebuild test -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'` passes.
- Display, window, and area recording each produce a playable `.mov`.
- Exported MP4 duration, frame rate, resolution, codec, audio presence, and frame count match the export manifest within test tolerances.
- Preview and export match for zoom, cursor, stage layout, masks, captions, fade, and camera PiP.
- Cursor position is correct for display, window, and area capture at top-left, center, bottom-right, and across Retina displays.
- Window recording has no known vertical cursor scale drift.
- Recorded cursor is not burned into source video; cursor rendering comes from metadata.
- Microphone, system audio, and camera toggles either work or fail with clear user-facing recovery text.
- No debug-only logs, diagnostics, or Japanese-only internal messages remain in user-facing paths.
- English is the default product language. Japanese can remain as a secondary localization.
- The app has no network dependency for core recording, editing, captioning, or export.
- There is no telemetry by default.
- App permissions are explainable from inside the UI: screen recording, microphone, camera, speech recognition, and accessibility if required.
- The README has a demo GIF/video, installation steps, build steps, feature list, architecture summary, roadmap, and license.
- The latest GitHub Release includes a downloadable signed or clearly marked unsigned macOS build.

### P1: Expected For Public Momentum

- Real cursor shapes render with correct hotspot, size, shadow, click pulse, and idle behavior.
- Auto zoom feels intentional, not merely cursor-following.
- Timeline editing supports trim, zoom segment adjustment, captions, masks, audio preview, and export without hidden state mismatch.
- Live preview uses the same rendering model as export or has documented differences covered by tests.
- Export supports at least 1080p/60 H.264, 1080p/60 HEVC, 720p/30 H.264, and social aspect ratios: 16:9, 9:16, 1:1, 4:3, 3:4.
- Long recordings of at least 20 minutes do not create unbounded project JSON or memory growth.
- Project files are backward-compatible within the supported schema range or fail with an actionable migration message.
- Errors are actionable and specific. Avoid generic "failed" messages when permissions, codec, disk, or source-window state is known.
- The app can be used without reading documentation after the first launch.
- Keyboard shortcuts, menu commands, accessibility labels, and undo/redo are consistent in editor workflows.

### P2: Differentiators

- Intent-aware zoom uses click, typing, pause, cursor path, and focus regions.
- Local caption generation supports at least English and Japanese reliably, with editable caption segments.
- Export presets target common use cases: Product Demo, Social Clip, Tutorial, Bug Report, App Store Preview.
- Contributor-friendly architecture docs explain capture, project model, timeline, auto zoom, compositor, and export validation.
- Good first issues are clearly scoped and do not require understanding the whole media pipeline.

## Competitive Quality Targets

ArcShot should not try to beat every competitor everywhere.

| Category | Their strength | ArcShot quality target |
| --- | --- | --- |
| Premium subscription demo recorder | Polished demo output | Similar visual quality, free OSS, local-first, native architecture |
| High-visibility OSS recorder | Star power and feature volume | Better Mac-native reliability and easier local build/run story |
| OSS auto pan/zoom editor | Community momentum | More credible native macOS implementation and permissive license |
| Cloud screen recorder | Sharing and teams | Better local privacy, export fidelity, and no required account |
| Screenshot-first capture utility | Fast still captures | Deeper demo video editing, not screenshot breadth |

## Feature Quality Criteria

### Capture

- Capture source selection must preserve the user's selected display, window, or area exactly.
- Capture dimensions must match the actual recorded content bounds.
- Cursor normalization rect must match the encoded video frame geometry.
- **Window capture:** use `SCStreamFrameInfo.screenRect` when it differs from `SCContentFilter.contentRect` (see `docs/INVARIANTS.md`).
- **AVCaptureSession:** never call `startRunning()` between `beginConfiguration()` and `commitConfiguration()`.
- **Launcher:** product recording starts from the floating bar with countdown; dev `RecordView` is not the primary UX.
- Stream stop, permission denial, source disappearance, disk write failure, and audio device failure must be handled distinctly.
- Stop/discard/finalize must not double-run or leave stale temporary files behind.

### Cursor

- Cursor samples use one coordinate convention throughout the project model.
- Export and preview use the same coordinate interpretation.
- Cursor shape classification must not change cursor position.
- Each pointer style must render at predictable size across 720p, 1080p, Retina, and vertical exports.
- Click effects must align to input events, not inferred video pixels.

### Auto Zoom

- Manual zoom always overrides generated zoom.
- Generated zoom must avoid rapid oscillation, unnecessary zoom during navigation, and excessive zoom during typing.
- Zoom target regions must stay inside the visible source bounds.
- Zoom ramps must be editable and deterministic.
- Changes to the algorithm version must invalidate stale stored analysis.

### Editor

- Timeline state is the source of truth for trim, speed, effect ranges, captions, masks, and clips.
- Selection, deletion, drag, undo, redo, and keyboard commands must operate on the same selected item.
- Preview playback time and source timeline time must stay explicitly mapped.
- UI must not rely on hidden Japanese strings for logic.
- Inspector controls must persist immediately or clearly show pending state.

### Export

- Export validation must check duration, resolution, codec, frame rate, and frame count.
- **Sandbox:** writes go to app-container temp first; user path requires `ExportOutputAccess` security scope.
- **Default preset:** new projects use source-resolution preset (`matchSource60`) unless user changes it.
- **Scaling:** compositor downscales use `highQualityDownsample: true` where applicable.
- Audio roles must remain deterministic for microphone, system audio, and background music.
- Export should not silently drop PiP, captions, masks, cursor, or zoom when the project contains them.
- Export support is MP4-only; new export formats must go through the same validation, cancellation, and temp-output promotion bar before being exposed in UI.
- Export should be cancellable without corrupting previous output.

### Localization And OSS Readiness

- English is the primary language for README, issue templates, release notes, and in-app defaults.
- Japanese strings should go through localization rather than direct literals in new UI.
- Permission copy should be short, plain English, and explain why the permission is needed.
- The repository must include `LICENSE`, `README.md`, `CONTRIBUTING.md`, and architecture docs before a public push.
- The README must state whether releases are signed/notarized.

## Verification Matrix

Run these before declaring a public-quality release.

| Area | Required check |
| --- | --- |
| Unit/integration tests | `xcodebuild test -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'` |
| Build | `xcodebuild build -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'` |
| Display recording | Record 30 seconds, move cursor through corners, export 1080p/60 |
| Window recording | Record 30 seconds, move cursor top-left/center/bottom-right, export 1080p/60 |
| Area recording | Record 30 seconds, verify selected area bounds and cursor alignment |
| Audio | Test none, mic only, system only, mic + system |
| Camera | Test PiP on/off, mirror, resize, and hidden segment |
| Timeline | Trim, split/move if available, speed change, zoom range edit, caption range edit, mask range edit |
| Export | H.264, HEVC, 16:9, 9:16, 1:1 |
| Permissions | Fresh install path for screen recording, mic, camera, speech recognition |
| README | Demo media works, build steps are current, release link works |

## Public Launch Definition

ArcShot is ready for an OSS launch when:

- All P0 criteria pass.
- The README can convince a developer in 30 seconds.
- A first-time user can download or build and produce a demo without asking for help.
- The demo video in the README shows the core value: record, auto zoom, edit, export.
- The issue tracker has labels for `bug`, `good first issue`, `help wanted`, `capture`, `editor`, `autozoom`, and `export`.

## Non-Goals

- Do not chase Windows or Linux before the macOS experience is excellent.
- Do not add cloud sharing as a core dependency.
- Do not compete with OBS on live streaming.
- Do not compete with screenshot-first capture utilities on still-image breadth.
- Do not add dependencies only to copy Electron-based competitors.
