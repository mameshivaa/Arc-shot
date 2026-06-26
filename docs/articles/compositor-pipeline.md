# Building a Swift screen-recorder export pipeline with custom `AVVideoCompositing`

*How ArcShot keeps cursor, zoom, PiP, and stage geometry consistent from ScreenCaptureKit capture through MP4 export.*

ArcShot is a **Swift / SwiftUI** macOS app: floating launcher → multi-track timeline → H.264/HEVC export. This article explains the hardest part — **making preview pixels match export pixels** when the cursor is *not* burned into the capture.

**Repo:** [github.com/mameshivaa/Arc-shot](https://github.com/mameshivaa/Arc-shot)

---

## The product constraint

Premium demo-video recorders look polished because they control the whole frame: zoom, cursor emphasis, backgrounds, PiP.

ArcShot does the same class of work, but with two extra engineering constraints:

1. **Local-first** — no upload compositor in the cloud.
2. **Inspectable** — Swift source, 260+ tests, documented invariants.

That means one native compositor path, not “preview in SwiftUI, export in FFmpeg with different math.”

---

## Capture: don’t burn the cursor

ScreenCaptureKit can draw the system cursor into every frame. We turn that off:

```swift
config.showsCursor = false
```

Instead, each frame stores:

- Video samples (BGRA)
- **Normalized cursor samples** (`RecordingProject.CursorSample`, 0…1, bottom-left origin)
- Optional click metadata for zoom / emphasis

The cursor is drawn later — in preview overlays and in `ArcShotVideoCompositor` — so zoom transforms apply to *content and cursor in one coordinate system*.

This mirrors how you’d build a serious recorder: capture is dumb, composition is smart.

---

## The bug that forces an invariant

Window capture has two rectangles that sound interchangeable but are not:

| Rect | Source | Problem |
| --- | --- | --- |
| `SCContentFilter.contentRect` | Filter setup | Often **~33pt above** the real window (title-bar inset) |
| `SCStreamFrameInfo.screenRect` | Per-frame stream attachment | Matches on-screen window bounds |

If you normalize mouse position against `contentRect` alone, the cursor renders **shifted upward** in preview and export.

**Invariant (do not break):**

```
mappingRect = latestStreamScreenRect ?? selection.contentRect
```

Implemented in `RecordingCoordinator.cursorMappingRect(for:)` and covered by unit tests. See [`docs/INVARIANTS.md`](../INVARIANTS.md) §1.

---

## Why we replaced Core Animation export

Older approach: `AVVideoCompositionCoreAnimationTool` + `CAKeyframeAnimation` for zoom.

Problems:

- Zoom and cursor lived in **different transform stacks**
- Sub-pixel drift between preview (SwiftUI) and export (CA layer tree)
- Hard to unit-test geometry

**Current approach:** custom `AVVideoCompositing` — `ArcShotVideoCompositor`.

One `processRequest` per output frame:

```
source CVPixelBuffer
  → CIImage
  → zoom transform + crop to render size
  → stage background (gradient / wallpaper / padding / shadow)
  → PiP camera layer
  → cursor draw (CGContext via CursorRenderer)
  → Metal-backed CIContext → output buffer
```

Key files:

| File | Role |
| --- | --- |
| `ArcShotVideoCompositor.swift` | `AVVideoCompositing` implementation |
| `ArcShotCompositionInstructionBuilder.swift` | Split timeline at zoom boundaries |
| `ArcShotCompositionInstruction.swift` | Per-segment zoom, cursor, effects |
| `CursorRenderer.swift` | Cursor shape, click pulse, interpolation |
| `Exporter.swift` | Wires `customVideoCompositorClass` |

---

## Instructions: one compositor, many segments

Zoom segments change crop geometry over time. The builder walks the timeline and emits **instructions** at boundaries — each instruction carries:

- Active zoom rectangle and easing
- Cursor samples for that time range
- Stage / PiP / caption parameters

`AVVideoComposition` calls `startRequest(_:)` on a dedicated queue; we render inside `autoreleasepool` blocks to keep long exports stable.

Export smoke tests sample output pixels at known coordinates — if cursor or PiP drifts by even a fraction of a point, CI fails.

---

## Preview vs export

Preview uses `AVPlayer` plus SwiftUI overlays that **reuse the same layout helpers** as the compositor (normalized rects, bottom-left → top-left only once at draw time).

We do **not** claim SwiftUI preview is pixel-identical to export in every edge case — but geometry invariants are shared, and export is the source of truth tested in `ExportSmokeTests`.

---

## Sandbox export

macOS sandbox cannot always write directly to user-picked folders. Pattern:

1. Render to a container temp file
2. Copy through a **security-scoped** bookmark (`ExportOutputAccess`)
3. Stop access

Documented in `INVARIANTS.md` §4. Boring code, production-critical.

---

## What we test

- Cursor mapping with `screenRect` offset from filter rect
- Compositor rect parity (preview helpers vs export probes)
- Export smoke tests with real fixture projects
- Launcher countdown → `startRecording` ordering on MainActor

Tests are the contract. [`docs/INVARIANTS.md`](../INVARIANTS.md) is the human-readable version.

---

## Build it yourself

```sh
git clone https://github.com/mameshivaa/Arc-shot.git
cd Arc-shot
open ArcShot.xcodeproj
xcodebuild test -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'
```

Requires macOS 26+, Xcode 17+, Screen Recording permission.

---

## Takeaways if you’re building something similar

1. **Turn off cursor burn-in** if you need zoom — you’ll thank yourself in export.
2. **Treat `screenRect` as ground truth** for window picks, not filter metadata alone.
3. **Custom `AVVideoCompositing` scales** when CA export and SwiftUI preview disagree.
4. **Write invariants down** before the next refactor — screen recorders accumulate subtle coordinate bugs fast.

---

*Questions or corrections: [GitHub Issues](https://github.com/mameshivaa/Arc-shot/issues).*
