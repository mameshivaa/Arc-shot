# M7-04 Compositor Rewrite Spike

Date: 2026-06-23

## Summary

Recommendation: **defer a compositor rewrite**.

The M7-03 split made the MP4 export pipeline stable enough to inspect and extend without rewriting `ArcShotVideoCompositor`. Current evidence does not show a concrete quality, speed, or maintainability gain large enough to justify a rewrite now. The compositor still has maintainability risks, but those risks are better handled by narrow extraction and benchmark coverage than by replacing the renderer without a measured target.

Use the existing compositor as the baseline for future work. Revisit a rewrite only with a benchmark harness that can compare export time, output size, and pixel-level visual quality across the same fixture set.

## Current Baseline

Measured from the latest required test run after M7-03 cleanup:

| Metric | Current value |
| --- | ---: |
| Full `ArcShotTests` execution | 252 tests, 0 failures, 11.465 s test execution |
| `ExportSmokeIntegrationTests` execution | 29 tests, 0 failures, 11.271 s |
| Xcode test operation elapsed | 17.830 s |
| Export preset validator matrix | 5 exports inside `testExporterValidatorCoversCodecsAndAspectRatios`, 2.846 s |
| Compositor source size | `ArcShotVideoCompositor.swift`: 866 lines |
| Instruction builder size | `ArcShotCompositionInstructionBuilder.swift`: 357 lines |
| Instruction payload size | `ArcShotCompositionInstruction.swift`: 316 lines |

Coverage already exercised by export smoke tests:

- trim, timeline clips, speed-adjusted clips
- source-resolution and aspect-ratio validation
- stage card, card shadow, gradient background, rounded clipping
- cursor densification and click pulse
- keyboard shortcut overlay, text overlay, caption track overlay
- intro/outro fade
- camera PiP mirroring, rounded clipping, temporal playback, timeline-speed playback, aspect-fill crop
- highlight mask and blur mask
- background music and preview/export audio role mapping
- cancellation preserving existing output

## Findings

- The compositor already uses a Metal-backed `CIContext` when available and keeps `highQualityDownsample: true` on the current downscale paths.
- The current renderer is broad but not blindly monolithic: instruction construction, timed data mapping, output promotion, video/audio pipeline setup, and reader/writer execution are now outside the compositor.
- Pixel-sensitive smoke tests cover the features that used to be rewrite candidates: stage, PiP, cursor, overlays, captions, masks, and fade.
- There is no competing compositor prototype with measured faster export time, smaller output files, or sharper rendered pixels.
- A Metal shader path could be useful later, but only if a benchmark isolates a hot downscale or compositing operation that Core Image cannot handle well enough.

## Current Problems

These are real issues, but they do not currently justify a full rewrite:

- `ArcShotVideoCompositor.swift` is still a large per-frame renderer. CoreImage video composition, CoreGraphics overlays, CoreText text drawing, cursor drawing, masks, stage, fade, and PiP all meet in one file.
- Preview and export do not share a single raster renderer. Preview uses SwiftUI-style rendering and shared geometry helpers, while export uses CoreImage/CoreGraphics/CoreText. The remaining risk is exact preview/export raster parity for text wrapping, glyph rendering, blur strength, shadows, gradients, cursor rasterization, and longer PiP sync.
- The compositor depends on careful coordinate-system handling across bottom-left video space, top-down CGContext drawing, stage transforms, and cursor mapping. Existing comments and tests protect this, but it remains a fragile boundary.
- Older handoff notes treated text overlays, visual masks, and full stage chrome as missing compositor work. That is no longer current: these are now rendered in the MP4 path, and the carry-forward risk is parity/maintainability rather than missing export rendering.

## Decision

Do **not** rewrite the compositor as part of M7.

M7-04 is complete as a spike with recommendation: **defer**. The next implementation work should be incremental:

- keep `ArcShotVideoCompositor` as the export rendering truth
- add narrow helpers only where repeated drawing logic becomes hard to maintain
- add benchmark tooling before attempting a renderer rewrite
- require any future compositor replacement to match the current export smoke fixture set before it can replace the current path

## Future Rewrite Gate

A future rewrite can proceed only if it provides all of these:

1. Same fixture set as `ExportSmokeIntegrationTests`.
2. Baseline and candidate numbers for export time.
3. Baseline and candidate output file sizes.
4. Pixel comparison or targeted luminance/color probes for sharpness-sensitive areas.
5. A fallback plan that preserves `ArcShotCompositionInstruction` semantics.
