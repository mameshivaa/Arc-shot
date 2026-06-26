# ArcShot

Native macOS screen recorder and demo video editor.

Record your screen, refine cursor movement and zoom on a timeline, add camera picture-in-picture, and export a polished MP4 — locally on your Mac, without a cloud account.

**Download:** [Mac App Store](https://apps.apple.com/) *(add your App Store URL)*

## Features

- Screen and window recording from a floating launcher
- Timeline editing: trim clips, audio, and camera segments
- Cursor rendering, click effects, keyboard shortcut overlays, and cursor-focus zoom
- Captions, visual masks, backgrounds, and stage styling
- Camera picture-in-picture with preview/export parity
- MP4 export (H.264 / HEVC) with common aspect ratios
- English and Japanese UI

## Requirements

- macOS 26.0 or later
- Xcode 17 or later (to build from source)
- Screen Recording permission (required)
- Microphone, Camera, and Speech Recognition permissions (optional)

## Build

Open `ArcShot.xcodeproj` and run the **ArcShot** scheme, or:

```sh
xcodebuild build -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'
```

Run tests:

```sh
xcodebuild test -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'
```

Set your own **Development Team** in Xcode before running on a device or archiving for distribution.

## Architecture

- `App/` — application shell, commands, localization
- `Domain/` — project model, persistence, timeline data
- `Features/Capture/` — screen, audio, microphone, and camera capture
- `Features/Editor/` — timeline editing, preview, inspector
- `Features/Export/` — AVFoundation export and custom compositor
- `Resources/` — assets, entitlements, localized strings

Read [`docs/INVARIANTS.md`](docs/INVARIANTS.md) before changing capture, export, or cursor code.

## Documentation

| Doc | Purpose |
| --- | --- |
| [`docs/INVARIANTS.md`](docs/INVARIANTS.md) | Hard rules backed by tests |
| [`docs/QUALITY_STANDARDS.md`](docs/QUALITY_STANDARDS.md) | Release quality bar |
| [`docs/MANUAL_VERIFICATION.md`](docs/MANUAL_VERIFICATION.md) | Manual QA checklist |
| [`HANDOFF.md`](HANDOFF.md) | Compositor pipeline notes |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | How to contribute |

## Marketing screenshots (maintainers)

```sh
./Scripts/capture-app-screenshots.sh
```

Uses the `-screenshotTour` launch flag to export App Store-style screenshots into `Marketing/Screenshots/`.

## Support

- Issues: https://github.com/mameshivaa/ArcShot/issues
- Privacy: [`PRIVACY.md`](PRIVACY.md)

## License

MIT — see [LICENSE](LICENSE).
