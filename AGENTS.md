# Agent instructions

## Core workflow

- Automatically invoke `$ponytail:ponytail`, `$i-have-adhd:i-have-adhd`, `$caveman`, and `$rtk` (or their plugins) for agentic development when installed and allowed.
- If `$rtk` is unavailable as a skill, prefix every shell command with `rtk`.
- Keep changes small, native, privacy-preserving, and easy to review. Reuse existing code; add no dependency without clear need.
- Preserve DiskSwell's boundary: detect and explain disk growth, never delete or modify monitored data. Networking stays limited to update checks and user-approved downloads.

## Project checks

- macOS 14+, Swift 6, SwiftUI menu-bar app; core tests are hostless.
- Run `swiftlint lint --strict` and `xcodebuild -project DiskSwell.xcodeproj -scheme DiskSwell -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO SWIFT_ENABLE_BATCH_MODE=NO test`.
- After editing `project.yml`, run `xcodegen generate` and commit generated project changes.
- Use Conventional Commit PR titles. Only merge a Release Please PR when intentionally publishing.
