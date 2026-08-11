#!/bin/bash
set -euo pipefail

if [[ -z "${DEVELOPMENT_TEAM:-}" || -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Set DEVELOPMENT_TEAM and NOTARY_PROFILE for Developer ID signing and notarization." >&2
    exit 2
fi

repo="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$repo/dist}"
identity="${CODE_SIGN_IDENTITY:-Developer ID Application}"
installer_identity="${INSTALLER_SIGN_IDENTITY:-Developer ID Installer}"
installer_scripts="$repo/Scripts/Installer"
work="$(mktemp -d /tmp/DiskSwell-release.XXXXXX)"
case "$work" in /tmp/DiskSwell-release.*) ;; *) echo "Unexpected temporary path" >&2; exit 2 ;; esac
cleanup() {
    if [[ -d "$work" && "$work" == /tmp/DiskSwell-release.* ]]; then rm -rf -- "$work"; fi
}
trap cleanup EXIT

mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
artifact="$output/DiskSwell.pkg"
checksum="$artifact.sha256"
if [[ -e "$artifact" || -e "$checksum" ]]; then
    echo "Refusing to overwrite $artifact or $checksum" >&2
    exit 1
fi

archive="$work/DiskSwell.xcarchive"
build_settings=()
if [[ -n "${MARKETING_VERSION:-}" ]]; then build_settings+=(MARKETING_VERSION="$MARKETING_VERSION"); fi
if [[ -n "${CURRENT_PROJECT_VERSION:-}" ]]; then build_settings+=(CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION"); fi
xcodebuild -project "$repo/DiskSwell.xcodeproj" -scheme DiskSwell -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" archive \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp "${build_settings[@]}"

app="$archive/Products/Applications/DiskSwell.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -d --entitlements "$work/entitlements.plist" "$app"
if [[ "$(plutil -extract com.apple.security.get-task-allow raw "$work/entitlements.plist" 2>/dev/null || true)" == true ]]; then
    echo "Release contains the debug get-task-allow entitlement." >&2
    exit 1
fi

pkg="$work/DiskSwell.pkg"
component_pkg="$work/DiskSwell-component.pkg"
pkgbuild --component "$app" --install-location /Applications --scripts "$installer_scripts" \
    --identifier com.diskswell.DiskSwell.pkg --version "$version" "$component_pkg"
productbuild --sign "$installer_identity" --package "$component_pkg" "$pkg"
pkgutil --check-signature "$pkg"

notary_settings=(--keychain-profile "$NOTARY_PROFILE")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then notary_settings+=(--keychain "$NOTARY_KEYCHAIN"); fi
xcrun notarytool submit "$pkg" "${notary_settings[@]}" --wait
xcrun stapler staple "$pkg"
xcrun stapler validate "$pkg"
pkgutil --check-signature "$pkg"
spctl --assess --type install --verbose=2 "$pkg"

ditto "$pkg" "$artifact"
(cd "$output" && shasum -a 256 "$(basename "$artifact")" > "$(basename "$checksum")")
echo "$artifact"
echo "$checksum"
