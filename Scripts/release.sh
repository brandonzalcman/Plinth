#!/bin/zsh
# Builds a release of Plinth: archive → Developer ID signing → notarization → DMG → Sparkle appcast.
#
#   Scripts/release.sh 0.2.0             signed, notarized release (needs the one-time setup in RELEASING.md)
#   UNSIGNED=1 Scripts/release.sh 0.2.0  local dry run: ad-hoc signed DMG, no notarization, no appcast
#
# Output: build/release/Plinth-<version>.dmg and build/release/appcast.xml
#
# Environment
#   TEAM_ID              Apple Developer Team ID (10 characters)
#   SPARKLE_PUBLIC_KEY   EdDSA public key from Sparkle's generate_keys (goes into Info.plist)
#   Notarization, either:
#     NOTARY_PROFILE     a keychain profile made with `xcrun notarytool store-credentials` (local), or
#     ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH   an App Store Connect API key (CI)
#   Sparkle signing, either:
#     the private key in your login keychain (generate_keys put it there; local), or
#     SPARKLE_KEY_FILE   a file holding the exported private key (CI)
#   PROVISIONING_PROFILE optional; path to a Developer ID provisioning profile for app.plinth.Plinth that
#                        includes the iCloud container. With it the build carries the iCloud (CloudKit)
#                        entitlement from App/Plinth.release.entitlements and iCloud sync works; without
#                        it the build has no iCloud, exactly as before (see RELEASING.md)
#   BUILD_NUMBER         optional; defaults to the number of commits, which always increases
#   RELEASE_NOTES        optional Markdown file shown in the update window
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION="${1:?usage: Scripts/release.sh <version, e.g. 0.2.0>}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
UNSIGNED="${UNSIGNED:-0}"
REPO_URL="https://github.com/brandonzalcman/Plinth"
OUT="build/release"
ARCHIVE="$OUT/Plinth.xcarchive"
DERIVED="$OUT/DerivedData"
APP="$OUT/export/Plinth.app"
DMG="$OUT/Plinth-$VERSION.dmg"

step() { print -P "%F{blue}==>%f $1"; }
fail() { print -P "%F{red}error:%f $1" >&2; exit 1; }

if [[ "$UNSIGNED" != 1 ]]; then
    [[ -n "${TEAM_ID:-}" ]] || fail "TEAM_ID is not set (see RELEASING.md)"
    [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]] || fail "SPARKLE_PUBLIC_KEY is not set (see RELEASING.md)"
    [[ -n "${NOTARY_PROFILE:-}" || ( -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ) ]] \
        || fail "set NOTARY_PROFILE, or ASC_KEY_ID + ASC_ISSUER_ID + ASC_KEY_PATH (see RELEASING.md)"
fi

rm -rf "$OUT"
mkdir -p "$OUT"

# Optional Developer ID provisioning profile (adds iCloud). Installed where xcodebuild looks for it.
PROFILE_NAME=""
if [[ "$UNSIGNED" != 1 && -n "${PROVISIONING_PROFILE:-}" ]]; then
    [[ -f "$PROVISIONING_PROFILE" ]] || fail "PROVISIONING_PROFILE is not a file: $PROVISIONING_PROFILE"
    security cms -D -i "$PROVISIONING_PROFILE" > "$OUT/profile.plist"
    PROFILE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$OUT/profile.plist")"
    PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$OUT/profile.plist")"
    PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$OUT/profile.plist")"
    rm "$OUT/profile.plist"
    [[ "$PROFILE_APP_ID" == "$TEAM_ID.app.plinth.Plinth" ]] \
        || fail "the provisioning profile is for '$PROFILE_APP_ID', not $TEAM_ID.app.plinth.Plinth"
    mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
    cp "$PROVISIONING_PROFILE" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.provisionprofile"
fi

# 1. Archive -----------------------------------------------------------------------------------
step "Archiving Plinth $VERSION ($BUILD_NUMBER)"
SIGNING=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
if [[ "$UNSIGNED" != 1 ]]; then
    SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application" DEVELOPMENT_TEAM="$TEAM_ID"
             "OTHER_CODE_SIGN_FLAGS=--timestamp")
    if [[ -n "$PROFILE_NAME" ]]; then
        SIGNING+=(CODE_SIGN_ENTITLEMENTS=App/Plinth.release.entitlements "PROVISIONING_PROFILE_SPECIFIER=$PROFILE_NAME")
    fi
fi
xcodebuild archive -quiet \
    -project Plinth.xcodeproj -scheme Plinth -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}" "${SIGNING[@]}"

# 2. Export ------------------------------------------------------------------------------------
mkdir -p "$OUT/export"
if [[ "$UNSIGNED" == 1 ]]; then
    step "Copying the ad-hoc signed app (UNSIGNED=1)"
    ditto "$ARCHIVE/Products/Applications/Plinth.app" "$APP"
    # Re-sign everything ad hoc, without the hardened runtime: ad-hoc code has no team, so with
    # library validation on it could not load Sparkle. (Signed releases keep the hardened runtime.)
    codesign --force --deep --sign - "$APP"
else
    step "Exporting with Developer ID${PROFILE_NAME:+ (with iCloud)}"
    PROFILE_OPTIONS=""
    if [[ -n "$PROFILE_NAME" ]]; then
        PROFILE_OPTIONS="<key>provisioningProfiles</key><dict><key>app.plinth.Plinth</key><string>$PROFILE_NAME</string></dict>
    <key>iCloudContainerEnvironment</key><string>Production</string>"
    fi
    cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
    $PROFILE_OPTIONS
</dict></plist>
PLIST
    xcodebuild -exportArchive -quiet -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
        -exportOptionsPlist "$OUT/ExportOptions.plist"
    codesign --verify --deep --strict "$APP"
    if [[ -n "$PROFILE_NAME" ]]; then
        codesign -d --entitlements - "$APP" 2>&1 | grep -q "iCloud.app.plinth.Plinth" \
            || fail "the exported app has no iCloud container entitlement"
    fi
fi

notarize() {  # notarize <file>, waits for Apple's verdict
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
    else
        xcrun notarytool submit "$1" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
    fi
}

# 3. Notarize the app --------------------------------------------------------------------------
if [[ "$UNSIGNED" != 1 ]]; then
    step "Notarizing the app"
    ditto -c -k --keepParent "$APP" "$OUT/Plinth-notarize.zip"
    notarize "$OUT/Plinth-notarize.zip"
    xcrun stapler staple "$APP"
    rm "$OUT/Plinth-notarize.zip"
fi

# 4. DMG ---------------------------------------------------------------------------------------
step "Building the disk image"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Plinth.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Plinth" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"

if [[ "$UNSIGNED" != 1 ]]; then
    step "Signing and notarizing the disk image"
    codesign --force --timestamp --sign "Developer ID Application" "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
fi
# The finished (signed, stapled) image again under the fixed name the landing page links to.

# 5. Sparkle appcast ---------------------------------------------------------------------------
if [[ "$UNSIGNED" != 1 ]]; then
    step "Writing the update feed"
    SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
    [[ -x "$SPARKLE_BIN/generate_appcast" ]] || fail "Sparkle tools not found in $SPARKLE_BIN"
    FEED="$OUT/feed"
    mkdir -p "$FEED"
    cp "$DMG" "$FEED/"   # the appcast enclosure is named after this file: Plinth-<version>.dmg
    [[ -n "${RELEASE_NOTES:-}" && -f "$RELEASE_NOTES" ]] && cp "$RELEASE_NOTES" "$FEED/Plinth-$VERSION.md"
    KEY_ARGS=()
    [[ -n "${SPARKLE_KEY_FILE:-}" ]] && KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE")
    "$SPARKLE_BIN/generate_appcast" "${KEY_ARGS[@]}" --embed-release-notes \
        --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" \
        --link "$REPO_URL" -o "$OUT/appcast.xml" "$FEED"
    rm -rf "$FEED"
fi

step "Done"
ls -lh "$DMG" "$OUT"/appcast.xml 2>/dev/null || true
