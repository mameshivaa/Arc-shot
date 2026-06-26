# ArcShot Task Breakdown

This file turns `docs/IMPLEMENTATION_GOALS.md` into issue-sized implementation tasks.

Priority order:

1. M0: restore build/test trust.
2. M1: fix capture and cursor correctness.
3. M2: make preview and export match.
4. M3+: polish and OSS launch work.

## Labels

Use these labels when creating GitHub issues:

- `p0`
- `p1`
- `p2`
- `capture`
- `cursor`
- `editor`
- `export`
- `autozoom`
- `localization`
- `docs`
- `oss`
- `testing`
- `good first issue`

## M0: Restore The Quality Gate

### M0-01 Fix XCTest compile errors

Labels: `p0`, `testing`

Problem:
`xcodebuild test` currently fails before tests run because some assertions use `accuracy:` with `XCTAssertGreaterThanOrEqual` or `XCTAssertLessThanOrEqual`.

Scope:

- Fix invalid XCTest assertion calls in `ArcShotTests/ArcShotTests.swift`.
- Do not change production code.
- Preserve the intent of each assertion.

Acceptance criteria:

- `ArcShotTests.swift` compiles.
- Full test command reaches test execution:
  - `xcodebuild test -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'`

### M0-02 Run and classify the full test suite

Labels: `p0`, `testing`

Problem:
After compile errors are fixed, the actual behavioral test state is unknown.

Scope:

- Run the full Xcode test command.
- Record failures by area: capture, editor, export, autozoom, localization, project model.
- Do not fix unrelated failures in this task unless they are trivial and local.

Acceptance criteria:

- Test result is documented in a local note or task comment.
- Any remaining failures are classified as behavioral, environment, or flaky.

### M0-03 Add manual media verification checklist

Labels: `p0`, `testing`, `docs`

Problem:
Media correctness cannot be fully covered by unit tests yet.

Scope:

- Add `docs/MANUAL_VERIFICATION.md`.
- Include display/window/area recording checks.
- Include cursor alignment points: top-left, center, bottom-right.
- Include export preset checks for 1080p/60 H.264 and HEVC.
- Include audio mode checks: none, mic only, system only, mic + system.

Acceptance criteria:

- Checklist is specific enough that another developer can run it.
- Checklist references output files or observations to record.

### M0-04 Audit debug-only logs

Labels: `p0`, `capture`, `docs`

Problem:
Public OSS builds should not expose diagnostic noise or stale cursor debugging.

Scope:

- Search for temporary `print`, `CURSORDBG`, and development-only log text.
- Decide for each item: remove, keep as structured logger, or gate behind debug.
- Do not remove useful production diagnostics from failure paths.

Acceptance criteria:

- No known temporary cursor diagnostics remain in release paths.
- Capture failure logs remain useful.

## M1: Capture Correctness

### M1-01 Reproduce window cursor vertical drift

Labels: `p0`, `capture`, `cursor`

Problem:
Window capture has a known or suspected cursor vertical scale mismatch.

Scope:

- Build a local app.
- Record a window while moving cursor through top-left, center, and bottom-right.
- Export to MP4.
- Compare preview cursor position vs exported cursor position.
- Record source window size, capture size, `contentRect`, and encoded video size.

Acceptance criteria:

- Drift is either reproduced with evidence or marked not reproducible with exact environment details.
- Evidence is enough to choose the fix path.

### M1-02 Fix cursor normalization geometry

Labels: `p0`, `capture`, `cursor`

Problem:
Cursor metadata must use the same geometry as the encoded video frame.

Scope:

- Fix normalization rect selection for display, window, and area capture.
- Prefer one authoritative capture geometry helper.
- Preserve `showsCursor = false`.
- Add unit tests for geometry helpers where possible.

Acceptance criteria:

- Cursor alignment passes manual verification for display/window/area.
- No regression in project cursor sample format.

### M1-03 Harden capture failure messages

Labels: `p1`, `capture`, `localization`

Problem:
User-facing capture failures need to be specific and English-first.

Scope:

- Separate messages for permission denial, source disappearance, stream stopped by system, writer failure, disk failure, mic/camera access denial.
- Move new text through localization.
- Keep Japanese as secondary localization.

Acceptance criteria:

- Known failure paths do not show generic raw errors when a specific explanation is available.
- English copy is the default.

### M1-04 Verify stop, discard, and finalization state

Labels: `p1`, `capture`, `testing`

Problem:
Recording lifecycle must not double-finalize or leave stale temporary files.

Scope:

- Test stop after normal recording.
- Test discard while recording.
- Test stream-stopped failure path.
- Test finalization failure path if practical.

Acceptance criteria:

- State returns to expected UI mode.
- No unusable project is created for discarded/failed recordings.
- Temporary screen/camera files are handled intentionally.

## M2: Preview Equals Export

Status: complete for M2 closeout on 2026-06-20.

Closeout decision:

- M2 is closed as the export-quality and preview/export-risk inventory phase.
- Major visual export paths now have deterministic unit or MP4 pixel coverage: zoom geometry, cursor coordinate mapping, sparse cursor densification, click pulse, keyboard shortcut overlay, stage background/shadow/rounded clipping, highlight/blur masks, text/captions, fade, and camera PiP placement/playback.
- Remaining preview-vs-export rendered raster parity work is intentionally moved out of M2 and tracked in `docs/PREVIEW_EXPORT_GAPS.md`.
- M3 can start without adding more M2 scope.

### M2-01 Inventory preview/export visual gaps

Labels: `p0`, `editor`, `export`

Status: complete.

Problem:
Preview and export must agree for user trust.

Scope:

- Compare `EditorView`/preview rendering against `ArcShotVideoCompositor`.
- Inventory support for zoom, cursor, click pulse, keyboard shortcut overlay, stage, masks, captions, fade, and camera PiP.
- Mark each as match, mismatch, or export-only.

Acceptance criteria:

- Add a short document or section listing all gaps.
- Each gap has an owner task.

Closeout evidence:

- `docs/PREVIEW_EXPORT_GAPS.md` lists zoom, cursor, click pulse, keyboard shortcut overlay, stage, masks, captions/text overlays, fade, and camera PiP.
- Each remaining risk is assigned to a follow-up item.

### M2-02 Share geometry for stage, zoom, cursor, and masks

Labels: `p0`, `editor`, `export`, `cursor`

Status: complete for M2.

Problem:
Duplicate coordinate math increases cursor and effect drift risk.

Scope:

- Identify duplicate geometry helpers.
- Move shared pure geometry into a common place if needed.
- Add tests around shared geometry.
- Avoid broad UI refactors.

Acceptance criteria:

- Preview/export use the same geometry for at least one high-risk path: cursor or masks.
- Existing tests pass.

Closeout evidence:

- Shared geometry and resolver tests cover high-risk coordinate paths for zoom, cursor, stage layout, and masks.
- Remaining raster differences are tracked rather than expanded inside M2.

### M2-03 Add export fixture with visual effects

Labels: `p1`, `export`, `testing`

Status: complete.

Problem:
Current export smoke coverage is too minimal for product quality.

Scope:

- Create a deterministic fixture project with cursor samples, click cues, one zoom segment, one mask, and one caption.
- Export it in test or generate verifiable metadata.
- Check output exists and export validator passes.

Acceptance criteria:

- Test proves enabled visual effects do not break export.
- Test remains deterministic on CI/local machines.

Closeout evidence:

- `ArcShotTests/ExportSmokeTests.swift` includes deterministic export smoke coverage for the major visual effects listed in `docs/PREVIEW_EXPORT_GAPS.md`.
- The M2 closeout verification command is `xcodebuild test -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:ArcShotTests/ExportSmokeIntegrationTests`.

## M3: Cursor Product Quality

Status: complete on 2026-06-20.

### M3-01 Implement real cursor shape rendering

Labels: `p1`, `cursor`, `export`

Status: complete on 2026-06-20.

Scope:

- Render arrow, I-beam, pointing hand, crosshair, resize cursors, open hand, closed hand, and operation-not-allowed.
- Define hotspot offsets for each shape.
- Keep existing pointer style options.

Acceptance criteria:

- Cursor shape changes do not shift target location.
- Output looks intentional at 720p, 1080p, 9:16, and 1:1.

Closeout evidence:

- `Features/Export/CursorRenderer.swift` now renders arrow, I-beam, pointing hand, crosshair, resize left/right, resize up/down, open hand, closed hand, operation-not-allowed, and unknown fallback shapes for arrow-style cursor rendering.
- `ArcShotTests/ArcShotTests.swift` covers every `RecordingProject.CursorShape` with a bitmap visibility test.
- Remaining visual QA is limited to manual demo inspection across export aspect ratios; no extra M3 scope is implied.

### M3-02 Tune cursor presets for demos

Labels: `p1`, `cursor`, `editor`

Status: complete on 2026-06-20.

Scope:

- Define practical defaults for spotlight, arrow, arrow with ring, and dot.
- Ensure click pulse and ring animation are not visually noisy.
- Make inspector settings understandable in English.

Acceptance criteria:

- Default cursor style works for README demo without manual adjustment.

## M4: Auto Zoom

Status: complete on 2026-06-20.

### M4-01 Audit current auto zoom behavior

Labels: `p1`, `autozoom`, `docs`

Status: complete on 2026-06-20.

Scope:

- Inventory the current `CursorZoomHeuristics`, `AutoZoomPipeline`, activity classifier, motion plan, editor insertion, recording finalization, and export resolver behavior.
- Identify which behavior is already covered by tests.
- Limit M4 implementation targets to a small set.

Acceptance criteria:

- Add a short audit document.
- M4 implementation targets are limited to 3-5 items.

Closeout evidence:

- `docs/AUTO_ZOOM_M4_AUDIT.md` records current entry points, existing behavior, test coverage, non-goals, and the next implementation target.

### M4-02 Improve intent-aware zoom heuristics

Labels: `p1`, `autozoom`, `testing`

Status: complete on 2026-06-20.

Scope:

- Improve click, typing, pause, navigation, and focus-region handling.
- Avoid zoom during fast navigation unless there is a clear target.
- Preserve manual override behavior.

Acceptance criteria:

- Tests cover click, typing, navigation no-zoom, idle no-zoom, and manual override.

Closeout evidence:

- `AutoZoomPipeline.Config.productDemo` now enables typing zoom for product paths while preserving the lower-level default config behavior.
- `AutoZoomPipeline.generate(from:)` and `generateWithFocusDetection(from:)` use the product demo config by default.
- `ArcShotTests/AutoZoomPipelineTests.swift` covers product demo typing zoom, fast navigation no-zoom, existing click zoom, idle/default no-zoom, and manual override suppression.

### M4-03 Add auto zoom comparison fixtures

Labels: `p2`, `autozoom`, `testing`

Status: complete on 2026-06-20.

Scope:

- Add small synthetic event/cursor traces that represent common demos.
- Store expected intent/segment output.

Acceptance criteria:

- Algorithm changes show intentional diff in tests.

Closeout evidence:

- Added synthetic product-demo traces for typing, fast navigation, and manual override to `AutoZoomPipelineTests`.
- Expected outputs are asserted at the intent/segment boundary so future algorithm changes must make intentional test diffs.

## M5: Export Reliability

Status: complete on 2026-06-20.

### M5-01 Expand export preset coverage

Labels: `p1`, `export`, `testing`

Status: complete on 2026-06-20.

Scope:

- Verify H.264 and HEVC export presets.
- Verify 16:9, 9:16, 1:1, 4:3, and 3:4.

Acceptance criteria:

- Export validator passes for covered presets.

Closeout evidence:

- `ExportSmokeIntegrationTests.testExporterValidatorCoversCodecsAndAspectRatios` exports H.264 and HEVC MP4s across 16:9, 9:16, 1:1, 4:3, and 3:4.
- The production `ExportValidator` validates render size, duration, frame rate, codec, and frame count before a file is promoted to the final output URL.

### M5-02 Test export cancellation safety

Labels: `p1`, `export`

Status: complete on 2026-06-20.

Scope:

- Start export.
- Cancel export.
- Confirm prior output is not corrupted.
- Confirm new partial output is handled intentionally.

Acceptance criteria:

- Cancellation leaves app and filesystem in a predictable state.

Closeout evidence:

- MP4 export now writes to a hidden temporary output first, validates that file, and only then replaces the requested output URL.
- `Exporter.stop()` cancels active reader/writer state and removes temporary output artifacts.
- `ExportSmokeIntegrationTests.testExporterCancellationPreservesExistingOutputAndRemovesPartialOutput` verifies an existing output file remains byte-for-byte unchanged after cancellation and temporary output files are cleaned up.

## M6: OSS Launch Readiness

Status: complete on 2026-06-20.

### M6-01 Make English default

Labels: `p0`, `localization`, `oss`

Status: complete on 2026-06-20.

Scope:

- Change default app language to English.
- Update tests accordingly.
- Keep Japanese selectable.

Acceptance criteria:

- Fresh install starts in English.
- Localization tests pass.

Closeout evidence:

- `AppLanguageStore` now defaults to `.english` when no language is stored.
- Xcode `developmentRegion` is now `en`; `knownRegions` still includes `ja`.
- `LocalizationTests` now asserts the fresh default is English and persistence keeps Japanese selectable.

### M6-02 Add public README

Labels: `p0`, `docs`, `oss`

Status: complete on 2026-06-20.

Scope:

- Add README headline:
  - `Open-source, local-first demo-video recorder for macOS`
- Include demo placeholder, install, build, features, architecture, roadmap, license, and signing status.

Acceptance criteria:

- A new developer can build from README steps.
- A new user understands the project in 30 seconds.

Closeout evidence:

- `README.md` includes the required headline, demo placeholder, requirements, build/test commands, features, architecture, roadmap, MIT license link, and signing status.

### M6-03 Add license and contribution docs

Labels: `p0`, `docs`, `oss`

Status: complete on 2026-06-20.

Scope:

- Add `LICENSE`.
- Add `CONTRIBUTING.md`.
- Add issue and PR templates.

Acceptance criteria:

- License choice is explicit.
- Contribution flow does not require Apple signing credentials.

Closeout evidence:

- `LICENSE` uses MIT.
- `CONTRIBUTING.md` states release signing credentials are not required for contribution.
- `.github/ISSUE_TEMPLATE/bug_report.md`, `.github/ISSUE_TEMPLATE/feature_request.md`, and `.github/PULL_REQUEST_TEMPLATE/pull_request_template.md` define public contribution templates.

## Suggested First Sprint

Do these first, in order:

1. M0-01 Fix XCTest compile errors.
2. M0-02 Run and classify the full test suite.
3. M0-03 Add manual media verification checklist.
4. M1-01 Reproduce window cursor vertical drift.
5. M1-02 Fix cursor normalization geometry.
6. M6-01 Make English default.
7. M6-02 Add public README outline.

---

## Closed: 2025-06 Capture / Export Stabilization

**Status:** complete — merged PR #1 to `main` (pre-OSS private development).

Closeout record: [`docs/CLOSED_MILESTONE_2025-06.md`](CLOSED_MILESTONE_2025-06.md)  
Hard rules: [`docs/INVARIANTS.md`](INVARIANTS.md)  
Tests at closeout: **252/252 passing**

---

## Next: Delegated Milestones (assign to other developers)

Full task specs, acceptance criteria, and GitHub issue templates:

**→ [`docs/NEXT_MILESTONES.md`](NEXT_MILESTONES.md)**

| Epic | Tasks | Primary owner skills |
| --- | --- | --- |
| **M7** Export pipeline redesign | M7-01 … M7-04 | AVFoundation, compositor, tests |
| **M8** Incamera UX | M8-01 … M8-04 | Capture, SwiftUI/AppKit, permissions |

Suggested pick-up order is documented in NEXT_MILESTONES.md.
