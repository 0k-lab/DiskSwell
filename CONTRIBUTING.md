# Contributing

Thanks for helping improve DiskSwell.

## Project boundaries

DiskSwell is a local, detection-only, bounded, native macOS utility. Changes must preserve those properties.

Do not add telemetry, analytics, accounts, networking beyond the fixed GitHub Releases updater, cleanup or deletion behavior, privileged helpers, or broad recurring filesystem scans. Report vulnerabilities through [SECURITY.md](SECURITY.md), not a public issue.

Open an issue before substantial changes so the scope can be agreed first. Small bug fixes, tests, documentation, accessibility, and performance improvements can go directly to a pull request.

## Development setup

Requirements:

- macOS 14 or later
- a current Xcode
- SwiftLint
- XcodeGen only when changing `project.yml`

Install the development tools with Homebrew if needed:

```sh
brew install swiftlint xcodegen
```

Run the same checks used by CI:

```sh
swiftlint lint --strict
xcodebuild -project DiskSwell.xcodeproj -scheme DiskSwell -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project DiskSwell.xcodeproj -scheme DiskSwell -configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

When `project.yml` changes, regenerate and commit the Xcode project:

```sh
xcodegen generate
```

## Making a change

- Branch from the latest `main`.
- Keep one pull request focused on one logical change. Split unrelated user-visible changes into separate PRs.
- Add the smallest regression test for non-trivial behavior.
- Update documentation when behavior or contributor workflow changes.
- Do not commit build products, credentials, certificates, API keys, notarization secrets, or personal Xcode state.

## Pull requests

Explain what changed, why it is needed, and how it was tested. All CI checks must pass.

The pull-request title must follow [Conventional Commits](https://www.conventionalcommits.org/) because maintainers squash-merge PRs and the title becomes the commit on `main`:

```text
type(optional-scope)!: short description
```

Common examples:

```text
fix: suppress unchanged notifications
feat(menu): show the responsible application
feat!: replace the persisted history format
docs: clarify monitoring permissions
```

Use:

- `fix:` for a user-visible correction; it contributes a patch release.
- `perf:` for a measurable performance correction; it contributes a patch release.
- `feat:` for new user-visible behavior; it contributes a minor release.
- `!` after any type for an incompatible change; it contributes a major release.
- `docs:`, `style:`, `test:`, `refactor:`, `build:`, `ci:`, `chore:`, or `revert:` for non-feature maintenance.

The title should describe the highest-impact change in the PR. Individual branch commits are squashed, so fixup commits do not become separate release-note entries.

## Releases

Contributors do not bump versions, edit release manifests, create tags, or prepare release notes.

After normal PRs reach `main`, Release Please collects their squash-merged titles into one release PR. That bot PR shows the proposed semantic version and all accumulated notes. A maintainer reviews and merges it when the batch is ready; CI then signs, notarizes, publishes the installer and checksum, and updates the Homebrew tap.

The repository intentionally has no tracked `CHANGELOG.md`; the release PR and GitHub Releases contain the notes. See [RELEASING.md](RELEASING.md) for maintainer details.

By submitting a contribution, you agree that it may be distributed under the repository's MIT License.
