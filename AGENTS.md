# AGENTS.md

## Role

You are the implementation worker. Do not act as project manager. Follow the task exactly.

## Project

- Swift / SwiftUI macOS app (ArcShot)
- Xcode project: `ArcShot.xcodeproj`
- Key areas: `App/`, `Domain/`, `Features/`, `Resources/`

## Mandatory reading (before capture / export / cursor changes)

**Read `docs/INVARIANTS.md` first.** It documents hard rules backed by regressions and unit tests.
Do not “simplify” code called out there without updating tests and the doc.

Also skim:

- `HANDOFF.md` — compositor pipeline
- `docs/QUALITY_STANDARDS.md` — release bar
- `docs/MANUAL_VERIFICATION.md` — manual QA when tests are insufficient

## Working rules

- Make the smallest safe change that satisfies the task.
- Do not redesign unrelated areas.
- Do not add dependencies unless explicitly required.
- Preserve existing behavior unless the task says otherwise.
- Prefer existing project conventions over new patterns.
- After editing, run the narrowest relevant test/check command.
- If tests cannot be run, explain why and provide the exact command the user should run.
- **Never** commit `.build/`, `.cursor/`, derived data, or local recordings.
- Add or extend **comments at invariant boundaries** when you touch capture/export hot paths (see `docs/INVARIANTS.md`).

## Protected hot paths (extra care)

| Area | Primary files |
| --- | --- |
| Cursor mapping | `RecordingCoordinator.swift`, `RecordingWriterSession.swift` |
| Mic / camera capture | `MicrophoneCapture.swift`, `CameraMovieCapture.swift` |
| Launcher countdown | `FloatingRecordingWidget.swift`, `CountdownOverlay.swift` |
| Export sandbox | `ExportOutputAccess.swift`, `Exporter.swift` |
| Compositor | `ArcShotVideoCompositor.swift`, `ArcShotCompositionInstructionBuilder.swift` |

## Output format

At the end, report:

1. files changed
2. behavior changed
3. commands run
4. test result
5. remaining risk
