#!/bin/zsh
# Exit 0 when a provisioning profile authorises an entitlement, 1 when it does not.
#
#   Scripts/profile-has-entitlement.sh <profile.provisionprofile | decoded.plist> <entitlement key>
#
# Used by Scripts/release.sh to sign in a restricted entitlement only when the profile carries it,
# since a restricted entitlement the profile does not authorise makes the signed app refuse to launch.
set -euo pipefail
[[ $# -eq 2 ]] || { print -u2 "usage: $0 <profile or decoded plist> <entitlement key>"; exit 2; }
PLIST="$(mktemp)"
trap 'rm -f "$PLIST"' EXIT
if ! security cms -D -i "$1" > "$PLIST" 2>/dev/null; then
    cp "$1" "$PLIST"   # already a decoded plist
fi
VALUE="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$2" "$PLIST" 2>/dev/null)" || exit 1
# Booleans must be true; arrays/strings (the key exists and has content) count as present.
[[ "$VALUE" != "false" ]]
