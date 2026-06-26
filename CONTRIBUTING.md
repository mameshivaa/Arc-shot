# Contributing

Thanks for helping improve ArcShot.

## Development Setup

1. Install Xcode 17 or newer.
2. Clone the repository.
3. Open `ArcShot.xcodeproj`.
4. Build and run the `ArcShot` scheme.

Command-line checks:

```sh
xcodebuild build -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'
xcodebuild test -project ArcShot.xcodeproj -scheme ArcShot -destination 'platform=macOS'
```

## Signing

You do not need ArcShot release signing credentials to contribute.

For local development, use your own Apple Development team, automatic signing, or ad-hoc signing as supported by your Xcode setup. Pull requests should not include private signing identities, provisioning profiles, certificates, or local team-specific project churn.

## Contribution Guidelines

- Keep changes small and focused.
- Prefer existing Swift, SwiftUI, and AVFoundation patterns already in the repository.
- Add focused tests when changing export, timeline, localization, or project-model behavior.
- Do not add dependencies unless the change clearly requires them.
- Do not commit generated build artifacts, derived data, private recordings, or local environment files.
- **Read [`docs/INVARIANTS.md`](docs/INVARIANTS.md) before modifying capture, cursor, launcher, or export code.**
- When you touch an invariant boundary, add a short comment in code pointing to the relevant section of `INVARIANTS.md`.

## Pull Requests

Before opening a pull request:

- Run the narrowest relevant test for your change.
- Run the full test command when touching shared export, timeline, project model, or localization behavior.
- Describe the user-facing behavior change and any remaining risk.

## Good first issues

New contributors are welcome. Look for issues labeled [**good first issue**](https://github.com/mameshivaa/Arc-shot/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22):

- Documentation improvements (README, export pipeline notes)
- Test fixtures and smoke-test coverage
- Localization string cleanup (English / Japanese)

Before touching capture, cursor, launcher, or export code, read [`docs/INVARIANTS.md`](docs/INVARIANTS.md).

## Issues

Useful issues include:

- Reproducible bugs with macOS version, Xcode version, and steps.
- Export files, screenshots, or short clips when they are safe to share.
- Focused feature requests that explain the workflow and expected output.
