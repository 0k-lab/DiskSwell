# Releasing DiskSwell

Normal pull requests are squash-merged into `main` after CI. Release Please collects those Conventional Commits in one release pull request and keeps its version and GitHub release notes current. Merging that release PR is the explicit approval to publish.

There is no release branch or tracked `CHANGELOG.md`. The release PR, Git tags, and GitHub Releases are the history.

## Versioning

Pull-request titles must use Conventional Commits. The squash-merged title determines each change's release impact:

- `fix: ...` or `perf: ...` contributes a patch change.
- `feat: ...` contributes a minor change.
- `feat!: ...`, `fix!: ...`, or a `BREAKING CHANGE:` footer contributes a major change.
- Documentation, test, CI, build, and chore-only commits do not create a release.

Release Please chooses the highest impact among all unreleased commits and groups all of them in the release notes. The manifest uses `0.9.0` only as a private bootstrap baseline, so the initial `feat: initial DiskSwell release` change produces the first public release, `v1.0.0`.

`version.txt` records the release version. CI supplies that semantic version to Xcode and uses `1000 + commit count` as the increasing `CURRENT_PROJECT_VERSION`.

## Automated release

`.github/workflows/ci-release.yml` performs the complete flow:

1. Run SwiftLint and the macOS unit tests for every pull request and `main` push.
2. After a successful normal merge, create or update the Release Please PR with all unreleased notes and the proposed version.
3. When that release PR is merged, create a tagged draft GitHub Release.
4. Import the Developer ID Application and Installer identities into a temporary keychain.
5. Archive the universal app, sign it, build the signed installer, notarize and staple it, and validate it with Gatekeeper.
6. Upload `DiskSwell.pkg` and `DiskSwell.pkg.sha256`, update `Casks/diskswell.rb` in `kricha-lab/homebrew-tap`, and publish the GitHub Release.

Those two asset names and the `vMAJOR.MINOR.PATCH` tag format are also the in-app updater contract; do not rename them without updating the app first.

The release job expects the Actions variable `APPLE_TEAM_ID` and the documented certificate, notarization, and `RELEASE_TOKEN` secrets. It removes temporary credentials even when the job fails. A rerun resumes an existing draft/tag, reuses uploaded assets when available, and retries the idempotent tap update.

The shared Xcode project intentionally leaves `DEVELOPMENT_TEAM` unset so contributors can use Sign to Run Locally or another team. Protect `main` with the `Tests and lint` check, require pull requests, and use squash merging.

## Local signed package

The release script can still be run locally when validating signing. Install both Developer ID identities and store notarization credentials in Keychain:

```sh
xcrun notarytool store-credentials DiskSwell-notary
DEVELOPMENT_TEAM=YOUR_TEAM_ID NOTARY_PROFILE=DiskSwell-notary MARKETING_VERSION=1.0.0 Scripts/package-release.sh
```

The script refuses to overwrite artifacts and produces:

```text
dist/DiskSwell.pkg
dist/DiskSwell.pkg.sha256
```

The package must use the branded icon from `DiskSwell/Assets.xcassets/AppIcon.appiconset`. Before the first public release, install the final package on a clean macOS 14-or-later account or VM and confirm Gatekeeper, Installer, automatic launch, menu monitoring, access limitations, notifications, and representative idle/heavy-load behavior.

## Homebrew

The owner-maintained tap installs with:

```sh
brew install --cask kricha-lab/tap/diskswell
```

The release workflow rewrites the cask version and SHA-256 before making the draft GitHub Release public. Migration to the official Homebrew cask repository can be considered after the project meets its acceptance requirements.
