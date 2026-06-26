# Show HN — draft post

Use this when submitting to [Hacker News](https://news.ycombinator.com/submit).

---

## Title (pick one)

**Recommended:**

> Show HN: ArcShot – Swift-native macOS demo recorder (open source, $7.99 one-time)

**Alternatives:**

> Show HN: I built an open-source ScreenCaptureKit + AVVideoCompositing screen recorder in Swift

> Show HN: ArcShot – macOS screen recorder with custom export compositor (Swift, 260+ tests)

---

## URL

```
https://github.com/mameshivaa/Arc-shot
```

Optional deep link for technical readers:

```
https://github.com/mameshivaa/Arc-shot/blob/main/docs/articles/compositor-pipeline.md
```

---

## Body (paste into “text” field)

```
ArcShot is a macOS screen recorder aimed at product demos: floating launcher, multi-track timeline (clip, audio, camera, zoom, captions), and MP4 export.

Stack: Swift, SwiftUI, ScreenCaptureKit, AVFoundation, custom AVVideoCompositing (Metal CIContext). No Electron.

I built it because polished demo recorders are mostly subscription now; this is buy-once ($7.99 on the Mac App Store) with full source on GitHub (MIT, third-party App Store redistribution not allowed).

Technical bit I’m proud of: cursor is NOT burned into capture (showsCursor = false). We record normalized cursor metadata and render in the same compositor as zoom/PiP/stage backgrounds, with preview/export geometry tested in 260+ unit/smoke tests.

Deep dive on the export pipeline:
https://github.com/mameshivaa/Arc-shot/blob/main/docs/articles/compositor-pipeline.md

macOS 26+, Xcode 17+. Clone and xcodebuild test if you want to kick the tires.

Happy to answer questions on capture invariants, compositor design, or sandboxed export.
```

---

## Timing tips

- Post **Tue–Thu, 8–11am US Eastern** (9pm–midnight JST) for best HN traffic.
- Be ready to reply in comments for 2–3 hours after posting.
- If asked about vs commercial tools: stay factual on pricing model, don’t name competitors unless asked.

---

## Reddit (optional)

**r/macapps** title:

> [App] ArcShot – Swift-native demo screen recorder, open source, $7.99 one-time

**r/swift** title:

> Open-source macOS screen recorder with custom AVVideoCompositing export pipeline

Link the compositor article in a comment, not only the repo root.
