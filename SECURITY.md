# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| Latest `main` | Yes |
| Older tags | Best effort |

## Reporting a vulnerability

**Please do not open public GitHub issues for security vulnerabilities.**

1. Open a private report via [GitHub Security Advisories](https://github.com/mameshivaa/Arc-shot/security/advisories/new) if available, **or**
2. Open a minimal [GitHub Issue](https://github.com/mameshivaa/Arc-shot/issues/new) and ask the maintainer to enable a private channel (do not paste exploit details publicly).

Include:

- Affected version / commit
- Steps to reproduce
- Impact assessment (sandbox escape, arbitrary file write, etc.)

## Scope notes

ArcShot is a **sandboxed macOS app** that requires Screen Recording, and optionally Microphone, Camera, and Speech Recognition. Reports about required macOS permissions themselves are generally out of scope unless they demonstrate unintended data exfiltration beyond the stated feature.
