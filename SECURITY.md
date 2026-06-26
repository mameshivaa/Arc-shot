# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| Latest App Store release | Yes |
| `main` branch | Yes |
| Older tags | Best effort |

## Reporting a vulnerability

**Please do not open public GitHub issues for security vulnerabilities.**

1. Open a private report via [GitHub Security Advisories](https://github.com/mameshivaa/Arc-shot/security/advisories/new) if available, **or**
2. Email the maintainer through the contact method listed on the [Mac App Store listing](https://apps.apple.com/app/arcshot/id6778335789) support section.

Include:

- Affected version / commit
- Steps to reproduce
- Impact assessment (sandbox escape, arbitrary file write, etc.)

## Scope notes

ArcShot is a **sandboxed macOS app** that requires Screen Recording, and optionally Microphone, Camera, and Speech Recognition. Reports about required macOS permissions themselves are generally out of scope unless they demonstrate unintended data exfiltration beyond the stated feature.
