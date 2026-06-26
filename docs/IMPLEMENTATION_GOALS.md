# ArcShot Implementation Goals

## North Star

ArcShot should be the open-source Screen Studio alternative for macOS.

The implementation goal is to make this promise true:

> Record a Mac app or website, generate tasteful zoom and cursor emphasis, make small edits, and export a polished demo locally.

This document converts `docs/QUALITY_STANDARDS.md` into implementation milestones.

## Guiding Constraints

- Keep ArcShot macOS-native. Prefer Swift, SwiftUI, ScreenCaptureKit, AVFoundation, Core Image, Metal, AppKit where needed.
- Do not add Electron, web runtime layers, or cloud dependencies.
- Do not broaden into a generic screenshot suite.
- Protect the existing non-destructive project model.
- Ship the smallest working slice for each milestone.
- Every feature that affects exported pixels needs preview/export consistency tests or a manual verification recipe.
- English is the default product surface for public OSS work.

## Milestone 0: Restore The Quality Gate

Goal: make the repo trustworthy before adding more features.

### Tasks

- Fix the current XCTest build failure in `ArcShotTests/ArcShotTests.swift`.
- Run the full test command and record the result:
  - `xcodebuild test -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'`
- Add or update a short local verification note for known manual media checks.
- Remove or gate debug-only capture logs before public release.
- Confirm the app builds from a clean checkout using the documented Xcode version.

### Acceptance Criteria

- Full test suite builds and runs.
- Failures, if any, are real behavioral failures rather than test compile errors.
- `docs/QUALITY_STANDARDS.md` P0 items have direct task references in this file.

## Milestone 1: Capture Correctness

Goal: make recording and metadata exact enough to trust.

### Tasks

- Fix window-recording cursor vertical scale drift.
- Verify cursor alignment for display, window, and area capture:
  - top-left
  - center
  - bottom-right
  - Retina display
  - external display when available
- Ensure cursor normalization rect equals the encoded frame geometry.
- Keep `SCStreamConfiguration.showsCursor = false` so cursor is rendered from metadata.
- Distinguish user-facing errors for:
  - screen recording permission denied
  - source window disappeared
  - stream stopped by system
  - disk/write failure
  - audio device failure
- Validate stop, discard, and finalization paths do not double-run.

### Acceptance Criteria

- A 30-second window recording exported to MP4 has cursor alignment within a small visible tolerance at all test points.
- Display and area captures do not regress.
- Capture failures leave no unusable project behind unless recoverable.

## Milestone 2: Preview Equals Export

Goal: users should trust what they see in the editor.

### Tasks

- Identify all visual effects rendered in export:
  - zoom
  - cursor
  - click pulse
  - keyboard shortcut overlay
  - stage background
  - rounded card
  - mask blur/highlight
  - captions/text overlays
  - fade
  - camera PiP
- Close gaps between `EditorView` preview rendering and `ArcShotVideoCompositor` export rendering.
- Prefer shared geometry helpers over duplicate coordinate math.
- Document any intentional preview/export differences.
- Add tests for shared geometry and effect timing where practical.

### Acceptance Criteria

- The same project visually matches in preview and exported MP4 for the core demo path.
- Geometry code for stage, cursor, mask, and zoom has one obvious source of truth.
- Known differences are documented and non-critical.

## Milestone 3: Cursor Product Quality

Goal: make cursor rendering a reason to star the project.

### Tasks

- Replace generic arrow-only rendering with real cursor shape assets or native vector equivalents.
- Implement hotspot offsets per shape:
  - arrow
  - I-beam
  - pointing hand
  - crosshair
  - resize left/right
  - resize up/down
  - open hand
  - closed hand
  - operation not allowed
- Keep spotlight, dot, arrow, and arrow-with-ring styles.
- Make click effects align with recorded `InputEvent` data.
- Tune cursor size for 720p, 1080p, 9:16, and 1:1 exports.
- Ensure cursor shape changes do not cause position jumps.

### Acceptance Criteria

- Cursor output looks intentional in demo videos without manual tuning.
- Cursor location and hotspot are correct across pointer styles.
- The README demo can clearly show cursor polish.

## Milestone 4: Auto Zoom That Feels Intentional

Goal: make auto zoom better than simple cursor-following.

### Tasks

- Use click, typing, pauses, cursor movement, and focus regions as separate intent signals.
- Avoid zoom during fast navigation unless there is a clear target.
- Avoid over-zooming on typing.
- Preserve manual zoom overrides.
- Make generated zoom segments editable and deterministic.
- Increment `AutoZoomAnalysis.currentAlgorithmVersion` when behavior changes incompatibly.
- Add fixtures/tests for:
  - click target
  - typing target
  - navigation no-zoom
  - idle no-zoom
  - manual override

### Acceptance Criteria

- Default auto zoom creates a useful demo in common product walkthrough recordings.
- Auto-generated segments can be adjusted in the timeline without fighting the algorithm.
- Tests cover the main intent classes.

## Milestone 5: Export Reliability

Goal: exported files should be boringly correct.

### Tasks

- Keep export manifest validation for duration, frame rate, resolution, codec, audio presence, and frame count.
- Add fixtures for projects containing:
  - cursor
  - zoom
  - captions
  - masks
  - stage layout
  - camera PiP
  - microphone/system audio roles
- Confirm export cancellation does not corrupt previous outputs.
- Keep export format support intentionally MP4-only; do not reintroduce lower-fidelity alternate paths without a full pipeline design.
- Verify H.264 and HEVC presets:
  - 1080p/60
  - 1080p/30
  - 720p/30
- Verify aspect ratios:
  - 16:9
  - 9:16
  - 1:1
  - 4:3
  - 3:4

### Acceptance Criteria

- Export failures are specific and actionable.
- Export tests cover more than a black-frame minimal project.
- Export does not silently drop enabled visual or audio features.

## Milestone 6: English-First OSS Readiness

Goal: make the project understandable and attractive to GitHub users.

### Tasks

- Make English the default app language.
- Move new user-facing strings through localization.
- Convert remaining permission and error copy to plain English first.
- Review `Info.plist` usage descriptions for public English copy.
- Reconsider `LSMinimumSystemVersion`; document why the minimum macOS version is required.
- Add public repo files:
  - `README.md`
  - `LICENSE`
  - `CONTRIBUTING.md`
  - issue templates
  - pull request template
- Add architecture docs:
  - capture pipeline
  - project model
  - auto zoom
  - timeline/editor
  - compositor/export
- Add labels for:
  - `bug`
  - `good first issue`
  - `help wanted`
  - `capture`
  - `editor`
  - `autozoom`
  - `export`

### Acceptance Criteria

- A new developer can build ArcShot from README alone.
- A new user can understand what ArcShot does within 30 seconds on GitHub.
- The repo clearly states signing/notarization status for downloadable builds.

## Milestone 7: Public Demo And Distribution

Goal: make the project star-worthy at first glance.

### Tasks

- Create a short demo video showing:
  - record
  - auto zoom
  - cursor/click polish
  - timeline adjustment
  - export
- Add README media above the fold.
- Create a GitHub Release with a downloadable macOS build.
- Decide signing status:
  - signed/notarized if available
  - clearly marked unsigned if not
- Add build-from-source fallback instructions.
- Add Homebrew cask only after releases are stable enough to install repeatedly.

### Acceptance Criteria

- The README demo makes the value obvious without reading long text.
- Users can try the app without cloning if a release build is provided.
- Build instructions remain valid for contributors.

## Implementation Order

1. Restore tests and build health.
2. Fix capture/cursor correctness.
3. Align preview and export.
4. Polish cursor rendering.
5. Improve auto zoom intent quality.
6. Harden export.
7. Prepare English-first OSS launch materials.
8. Publish demo and release.

## First Concrete Task List

Start here before broader roadmap work:

- Fix `ArcShotTests.swift` compile errors from invalid XCTest `accuracy:` arguments.
- Run full `xcodebuild test`.
- Reproduce or close the window cursor vertical drift issue.
- Create a manual verification checklist file for display/window/area cursor alignment.
- Make English the default app language.
- Audit user-facing Japanese literals in capture errors and permission setup.
- Add README outline focused on "open-source Screen Studio alternative for macOS."

## Definition Of Done

An implementation milestone is done only when:

- The relevant code path is implemented.
- The narrowest useful automated test passes.
- Manual media verification is documented when automation is not practical.
- User-facing behavior is described in release notes or docs.
- No unrelated redesign or dependency was introduced.
