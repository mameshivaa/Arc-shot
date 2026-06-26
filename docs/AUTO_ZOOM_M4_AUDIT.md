# M4 Auto Zoom Audit

Date: 2026-06-20

Purpose: close M4-01 by recording the current auto zoom behavior and limiting M4 implementation scope. This is an audit only; no production behavior is changed here.

## Current Entry Points

- Recording finalization creates initial auto zoom suggestions with `CursorZoomHeuristics.suggestZoomKeyframes`.
- Editor and trim review insertion first try `AutoZoomPipeline.generate(from:assetDurationSeconds:)`, then fall back to `CursorZoomHeuristics.suggestZoomKeyframes` when the pipeline produces no segments.
- Export uses `AutoZoomMotionResolver.resolve` for `.cursorFocus` projects without manual zooms. It prefers persisted `autoZoomAnalysis`, otherwise generates a cursor/input driven motion plan.
- Manual or instant zoom segments suppress generated auto zoom motion in export resolution.

## Current Behavior

- Click zoom exists in both the legacy heuristic path and the newer pipeline path.
- Dwell/slow-cursor zoom exists in `CursorZoomHeuristics`.
- Activity classification already detects clicking, typing bursts, dragging, navigating, idle, and scroll-like motion.
- `ZoomIntentPlanner` has typing target logic and focus-region support, but `enableTypingZoom` is currently false by default.
- Navigation, dragging, scrolling, idle, and overview scales are set to `1.0`, so those activities currently avoid zooming unless focus-region or fallback behavior changes the target.
- Motion smoothing exists in `AutoZoomMotionPlan` to suppress tiny anchor/scale jitter.

## Existing Test Coverage

- `ArcShotTests/ArcShotTests.swift` covers legacy click zoom priority, click overlap with existing zoom, near-end click zoom, dwell/click deduplication, and nearby click merge behavior.
- `ArcShotTests/AutoZoomPipelineTests.swift` covers activity classification, typing target planning, focus regions, camera track segment generation, motion interpolation, smoothing, and persisted analysis resolution.
- M2 export smoke coverage verifies the zoom/export path broadly, but M4 should not expand export pixel coverage unless a specific auto zoom export bug is found.

## M4 Implementation Targets

1. Click/typing intent zoom: keep click zoom conservative, then decide whether to enable typing zoom by default or expose it through a safer preset.
2. Dwell/pause zoom safety: keep useful dwell zooms, but add explicit no-zoom coverage for short pauses and fast navigation.
3. Safety rules: preserve manual zoom priority, clamp edge anchors, limit generated segment duration, and merge nearby targets without excessive zooming.
4. Pipeline/heuristic boundary: decide whether `CursorZoomHeuristics` remains a fallback only, or whether key rules should move into `AutoZoomPipeline`.

## Non-Goals For M4

- Do not add README/demo/launch work.
- Do not broaden preview/export raster parity work.
- Do not introduce ML or remote analysis.
- Do not replace the timeline or export pipeline.

## Closeout Decision

M4-01 is complete. The next implementation task should be M4-02: add focused tests for click/typing intent zoom and manual-overlap safety before changing defaults.
