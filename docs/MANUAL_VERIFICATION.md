# ArcShot Manual Verification

Use this checklist when media behavior cannot be proven by automated tests.

Record the date, machine, macOS version, display setup, ArcShot commit, and output file path for every run.

## Environment

- Date:
- Commit:
- macOS version:
- Mac model:
- Display setup:
  - built-in display:
  - external display:
  - Retina scale:
- Xcode version:
- ArcShot build type:
  - Debug
  - Release
  - signed
  - unsigned

## Required Commands

Run before manual media verification:

```sh
xcodebuild test -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'
```

If test execution is not possible, record the exact failure and do not mark the release as public-ready.

## Launcher Countdown + Mic (regression checklist)

Added after countdown freeze bug (2025-06). See `docs/INVARIANTS.md` §2–3.

Steps:

1. Open floating recording launcher (⌘⇧L).
2. Enable **Microphone** on the launcher bar.
3. Select a window target.
4. Tap REC; wait for 3-2-1 countdown.
5. Confirm recording starts (mini bar top-right, timer running) without beach ball.
6. Stop recording; confirm finalize opens editor or expected flow.

Expected:

- No `startRunning may not be called between beginConfiguration and commitConfiguration` in console.
- Countdown overlay dismisses before or as recording begins.
- Mic audio present in exported file when enabled.

## Capture Matrix

### Display Capture

Record at least 30 seconds.

Steps:

1. Select full display capture.
2. Move the cursor to the top-left, center, and bottom-right of the captured display.
3. Click once at each point.
4. Type one visible keyboard shortcut, such as Command-S.
5. Stop recording.
6. Export 1080p/60 H.264.
7. Export 1080p/60 HEVC if available.

Expected:

- Source video is playable.
- Exported MP4 is playable.
- Cursor is not burned into the source recording.
- Rendered cursor aligns with the actual target points.
- Click pulses align with click events.
- Keyboard shortcut overlay appears at the correct time if enabled.
- Export duration roughly matches recording duration.
- No visible frame corruption or black frames.

Record:

- Source `.mov` path:
- Export `.mp4` path:
- Cursor alignment result:
- Audio result:
- Notes:

### Window Capture

Record at least 30 seconds.

Steps:

1. Select a normal resizable app window.
2. Move the cursor to the window top-left, center, and bottom-right.
3. Click once at each point.
4. Resize or move nothing during the capture unless testing source changes explicitly.
5. Stop recording.
6. Export 1080p/60 H.264.

Expected:

- Cursor position matches preview and export at all three points.
- No vertical cursor scale drift from top to bottom.
- Encoded video bounds match the selected window content area or the documented crop behavior.
- Window shadow/fringe handling does not change cursor alignment.

Record:

- Source window app/name:
- Source window size:
- Capture size:
- Encoded video size:
- Export path:
- Top-left alignment:
- Center alignment:
- Bottom-right alignment:
- Notes:

### Area Capture

Record at least 30 seconds.

Steps:

1. Select a custom rectangular area.
2. Move cursor to the top-left, center, and bottom-right of the selected area.
3. Click once at each point.
4. Stop recording.
5. Export 1080p/60 H.264.

Expected:

- Selected area bounds match the recorded video.
- Cursor aligns with the selected area, not the full display.
- Exported output respects stage and aspect-ratio settings.

Record:

- Selected area:
- Capture size:
- Encoded video size:
- Export path:
- Cursor alignment result:
- Notes:

## Audio Matrix

Run at least one short capture for each mode.

| Mode | Expected | Result |
| --- | --- | --- |
| No audio | Export has no unintended audible track | |
| Microphone only | Microphone is audible and not muted | |
| System audio only | System audio is audible and not swapped with mic | |
| Microphone + system audio | Both tracks are present and mixed according to project settings | |

Notes:

- Confirm the waveform lane reflects available audio where applicable.
- Confirm export does not silently drop enabled audio.

## Camera PiP

Run with a short capture that enables camera.

Steps:

1. Enable camera.
2. Record 15 seconds.
3. Open editor.
4. Verify PiP appears in preview.
5. Export 1080p/60 H.264.

Expected:

- Camera recording is aligned with screen recording.
- PiP appears in export when enabled.
- Hidden camera segment does not appear in export.
- Mirror and resize settings behave as shown in preview.

Record:

- Camera output path:
- Export path:
- Preview result:
- Export result:
- Notes:

## Timeline And Effects

Use one project with at least 20 seconds of footage.

Steps:

1. Trim the clip.
2. Add or adjust one zoom segment.
3. Add one caption segment.
4. Add one blur mask.
5. Add one highlight mask.
6. Toggle cursor visibility and click effects.
7. Export 16:9 and 9:16.

Expected:

- Preview and export match for zoom, cursor, caption, mask, fade, and stage layout.
- Timeline selection, delete, undo, and redo affect the intended item.
- Export does not silently drop enabled effects.

Record:

- Project path:
- 16:9 export:
- 9:16 export:
- Preview/export mismatches:
- Notes:

## Export Presets

Run on a known-good project.

| Preset | Expected | Result |
| --- | --- | --- |
| 1080p/60 H.264 16:9 | Correct size, codec, frame rate, duration | |
| 1080p/60 HEVC 16:9 | Correct size, codec, frame rate, duration | |
| 1080p/30 H.264 9:16 | Correct size, codec, frame rate, duration | |
| 720p/30 H.264 1:1 | Correct size, codec, frame rate, duration | |

If a preset is not available in the UI, record that as a product gap rather than passing the check.

## Permission Flows

Use a fresh install or reset permissions before testing.

| Permission | Expected | Result |
| --- | --- | --- |
| Screen recording | App explains why permission is needed and how to recover | |
| Microphone | Toggle requests or explains permission | |
| Camera | Toggle requests or explains permission | |
| Speech recognition | Caption feature requests or explains permission | |

Notes:

- Public OSS builds should default to English permission copy.
- Recovery text should not rely on internal debug details.

## Pass Criteria

A public-quality release requires:

- All automated tests pass or failures are classified and intentionally accepted.
- Display, window, and area cursor alignment pass.
- Window capture has no known vertical cursor scale drift.
- At least one H.264 export and one HEVC export pass validation.
- Enabled visual effects appear in both preview and export.
- Enabled audio/camera features are not silently dropped.
- Permission failures are understandable to a first-time user.
