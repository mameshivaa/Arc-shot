# Next Milestones — Delegated Tasks

These milestones are **intentionally not started** in the 2025-06 stabilization closeout.  
Assign to a developer familiar with AVFoundation and/or capture UX.

**Before any PR:** read `docs/INVARIANTS.md` and run the full test suite.

**Closed baseline:** `docs/CLOSED_MILESTONE_2025-06.md` (PR #1 on `main`).

---

## Labels (GitHub)

| Label | Use |
| --- | --- |
| `p1` | Should ship before next public release |
| `export` | Export / compositor |
| `capture` | Recording / camera |
| `architecture` | Structural refactor |
| `testing` | Test coverage required |

Suggested epic issues:

- **M7** Export pipeline analysis & redesign
- **M8** Incamera recording UX

---

# M7 — Export Pipeline Analysis & Redesign

**Epic owner:** TBD  
**Primary files:** `Features/Export/Exporter.swift`, `ArcShotVideoCompositor.swift`, `ArcShotCompositionInstructionBuilder.swift`, `ExportMixedCompositionBuilder.swift`  
**Related docs:** `HANDOFF.md`, `docs/PREVIEW_EXPORT_GAPS.md`, `docs/INVARIANTS.md` §5–6

**Status:** Complete. M7-01 through M7-04 are documented and verified against the current MP4 export pipeline.

## Problem statement

`Exporter.swift` is a large, multi-responsibility module (~2000 lines) that owns:

- Asset reading / timeline composition assembly
- Custom `AVVideoCompositing` instruction building
- AVAssetReader/Writer pump loops (MP4)
- Export validation manifest
- Sandbox temp output + security-scoped copy (`ExportOutputAccess`)
- Cursor densification, zoom/motion plan wiring, audio mix

The custom compositor (`ArcShotVideoCompositor`) now renders the main instruction-carried export visuals: zoom, stage background/card/shadow/rounded clipping, PiP, cursor/click, text/captions/keyboard shortcuts, masks, and fades.

Quality work (match-source presets, HQ downscale) and feature parity work were added incrementally. M7 fixed the large export ownership problem first; the remaining compositor risk is maintainability and preview/export raster parity, not a known missing MP4 export feature.

## Goals

1. **Map** the current export data flow end-to-end with a diagram (asset → composition → compositor → encoder → validator → user URL).
2. **Identify** duplication between preview geometry and export geometry; close gaps listed in `docs/PREVIEW_EXPORT_GAPS.md`.
3. **Propose** a target architecture (modules, boundaries, test seams) — rewrite only if the proposal proves smaller/safer than incremental extraction.
4. **Preserve** invariants in `docs/INVARIANTS.md` §4–6 unless explicitly revised with tests.

## Non-goals (M7)

- Changing capture / cursor mapping (M1 closed — see INVARIANTS §1)
- New export presets beyond what exists (unless required by redesign)
- Cloud upload or non-local export paths

---

## M7-01 Export pipeline inventory & diagram

**Labels:** `p1`, `export`, `architecture`, `docs`  
**Estimate:** 1–2 days  
**Depends on:** none

### Scope

- Read `Exporter.startExportWork`, `makeVideoPipeline`, `runExport`, `ExportCompositionPlanner`, `ExportTimedDataMapper`, `ExportMixedCompositionBuilder`.
- Document each phase: inputs, outputs, thread (MainActor vs `exportQueue`), failure modes.
- Produce a diagram (Mermaid or ASCII) checked into `docs/export/PIPELINE.md` (new file).

### Acceptance criteria

- [x] New doc lists every major function cluster and file ownership
- [x] Diagram covers MP4 happy path and cancel path
- [x] Lists known preview/export gaps with file references

### Verification

- Complete in `docs/export/PIPELINE.md`.

---

## M7-02 Compositor feature parity audit

**Labels:** `p1`, `export`, `testing`  
**Estimate:** 2–3 days  
**Depends on:** M7-01

### Scope

- Compare `ArcShotCompositionInstruction` fields vs what `ArcShotVideoCompositor.processRequest` actually renders.
- Compare editor preview (`EditorView` / `VideoPreviewPane`) vs compositor for: zoom, stage, PiP, cursor, captions, masks, fades.
- Extend or add `ExportSmokeIntegrationTests` for any gap found **or** document as intentional with manual recipe.

### Acceptance criteria

- [x] Checklist table: feature × preview × export × test name
- [x] Each “missing in export” item becomes a sub-task or explicit wont-fix with reason
- [x] Full test suite still passes

### Verification

```sh
xcodebuild test -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'
```

---

## M7-03 Extract export phases (minimal refactor)

**Labels:** `p1`, `export`, `architecture`  
**Estimate:** 3–5 days  
**Depends on:** M7-01, M7-02

### Status

Major M7-03 splitting is complete without behavior change. `ExportCompositionPlanner`, `ExportTimedDataMapper`, `ExportPIPTimelineSourceMapper`, `ExportOutputPromotion`, `ExportVideoPipelineFactory`, and `ExportReaderWriterSession` are extracted.

Remaining M7-03 work is cleanup-level: keep `Exporter` as the export orchestrator, avoid moving sandbox access or promotion into lower-level helpers, and only add more seams when they reduce real complexity.

Keep public `Exporter` API stable for `ExportView`.

### Acceptance criteria

- [x] No diff in exported pixels for `ExportSmokeIntegrationTests` fixture set (or explain intentional deltas)
- [x] `Exporter.swift` remains an orchestrator; new files keep focused ownership
- [x] `docs/INVARIANTS.md` updated if boundaries change
- [x] 252/252 tests pass

### Verification

- Full test suite passes. Manual verification was intentionally skipped for this M7 implementation pass.

---

## M7-04 Compositor rewrite spike

**Labels:** `p2`, `export`, `architecture`  
**Estimate:** time-boxed 3 days  
**Depends on:** M7-03

### Status

Complete. See [`docs/export/COMPOSITOR_REWRITE_SPIKE.md`](export/COMPOSITOR_REWRITE_SPIKE.md).

Recommendation: defer a compositor rewrite. Current tests and baseline numbers do not justify replacing `ArcShotVideoCompositor` now; future work should target narrow helpers or benchmark tooling before any renderer replacement.

### Scope

- Spike only: prototype alternative compositor structure OR Metal shader path for hot downscale.
- Deliver recommendation: proceed / defer / reject with benchmarks (export time, file size, visual sharpness).
- Proceed only if the hypothesis is measurable against M7-03's stable MP4 pipeline. Defer if the expected quality, speed, or maintainability gain is unclear.

### Acceptance criteria

- [x] Spike branch or doc with benchmark numbers
- [x] No compositor rewrite merged to `main`

---

# M8 — Incamera Recording UX

**Epic owner:** TBD  
**Primary files:** `Features/Capture/CameraMovieCapture.swift`, `RecordingCoordinator.swift`, `RecordingLauncherBarDesign.swift`, editor PiP attachment model  
**Related docs:** `docs/INVARIANTS.md` §2, `HANDOFF.md`

## Problem statement

Camera is recorded today as a **separate sidecar `.mov`** via `CameraMovieCapture` when the launcher camera toggle is ON. It is not a unified “incamera” product experience:

- No in-launcher camera preview
- No explicit record-start/stop UX for camera beyond the toggle
- PiP placement is editor/export time, not capture-time WYSIWYG
- Future “incamera” mode (facecam-first or dual-stream) needs a product spec

## Goals

1. Define **incamera modes** (minimum: optional facecam overlay metadata + sidecar; stretch: preview in launcher).
2. Integrate with existing `RecordingCoordinator` lifecycle without breaking countdown / mic / system audio invariants.
3. Persist enough metadata in `RecordingProject` for editor/export PiP defaults.
4. Full permission and failure UX (camera denied, device missing, session interrupt).

## Non-goals (M8)

- Replacing ScreenCaptureKit screen capture with camera-only recording (unless spec’d separately)
- Windows / iOS
- Beauty filters / AR

---

## M8-01 Product spec & UX wireframe

**Labels:** `p1`, `capture`, `docs`  
**Estimate:** 1–2 days  
**Depends on:** none

### Scope

- Document user stories: “facecam in corner while recording window”, “camera only for PiP in editor”, “mirror default”.
- Wireframe launcher states: camera off, permission needed, preview visible, recording.
- Decide: sidecar `.mov` retained vs single multiplexed file (likely keep sidecar initially).

### Acceptance criteria

- [ ] `docs/incamera/SPEC.md` (new) approved by product owner
- [ ] Explicit list of launcher UI changes vs editor-only changes

### Verification

- Review only

---

## M8-02 Camera session lifecycle hardening

**Labels:** `p1`, `capture`, `testing`  
**Estimate:** 2–3 days  
**Depends on:** M8-01

### Scope

- Audit `CameraMovieCapture` against INVARIANTS §2 (already uses begin/commit/startRunning order).
- Add tests where possible (mock/device-less): start/stop ordering, error propagation to `RecordingCoordinator`.
- Ensure `stopRecording` / `discardRecording` always finalize or delete sidecar cleanly.

### Acceptance criteria

- [ ] Unit or integration tests for camera start/stop error paths
- [ ] No leak of temp `.mov` files after discard
- [ ] Manual: record with camera ON → stop → sidecar present in project bundle

### Verification

```sh
xcodebuild test -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'
```

Manual steps in `docs/MANUAL_VERIFICATION.md` (new § Incamera when added).

---

## M8-03 Launcher camera preview surface

**Labels:** `p1`, `capture`  
**Estimate:** 3–5 days  
**Depends on:** M8-01, M8-02

### Scope

- Optional small preview in launcher when camera toggle ON (NSViewRepresentable / AVCaptureVideoPreviewLayer or equivalent).
- Respect sandbox + camera entitlement (`Resources/ArcShot.entitlements`).
- Do not block screen recording start; preview failure degrades gracefully.

### Acceptance criteria

- [ ] Preview visible when camera enabled and permitted
- [ ] Countdown + mic + system audio flows unchanged (INVARIANTS §3)
- [ ] Accessibility labels on camera controls

### Verification

- Manual: launcher countdown → record with camera + mic per `docs/MANUAL_VERIFICATION.md`

---

## M8-04 Project model & editor handoff

**Labels:** `p1`, `capture`, `editor`, `export`  
**Estimate:** 2–4 days  
**Depends on:** M8-02

### Scope

- Ensure `RecordingProject` stores camera attachment defaults (path, mirror, layout hints) at finalize.
- Editor opens with sensible PiP default from capture metadata.
- Export uses existing PiP pipeline without regression.

### Acceptance criteria

- [ ] New recording with camera produces editor PiP without manual re-import
- [ ] Export smoke tests with camera segments still pass
- [ ] Update `docs/INVARIANTS.md` §9 → promote stable rules into main sections when done

---

## Suggested assignment order

**Track A — Export (AVFoundation-heavy):** M7-01 → M7-02 → M7-03 → (optional M7-04)

**Track B — Incamera (Capture + UI):** M8-01 → M8-02 → M8-03 → M8-04

Tracks are independent; coordinate only on shared `RecordingCoordinator` API changes.

---

## Creating GitHub issues

Copy each `M7-xx` / `M8-xx` section into a GitHub issue. Title format:

```
[M7-01] Export pipeline inventory & diagram
[M8-01] Incamera product spec & UX wireframe
```

Link epic issues in description:

```
Epic: Export pipeline redesign (M7)
Baseline: docs/CLOSED_MILESTONE_2025-06.md
Rules: docs/INVARIANTS.md
```
