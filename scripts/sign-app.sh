#!/bin/bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: $0 APP_PATH QUICK_LOOK_EXTENSION_ENTITLEMENTS APP_ENTITLEMENTS SIGNING_IDENTITY" >&2
    exit 64
fi

app_path="$1"
extension_entitlements="$2"
app_entitlements="$3"
signing_identity="$4"
quicklook_path="$app_path/Contents/PlugIns/SeizaQuickLook.appex"
thumbnail_path="$app_path/Contents/PlugIns/SeizaThumbnail.appex"
sparkle_path="$app_path/Contents/Frameworks/Sparkle.framework"
sparkle_version_name="$(readlink "$sparkle_path/Versions/Current")"
sparkle_version_path="$sparkle_path/Versions/$sparkle_version_name"
script_directory="$(cd "$(dirname "$0")" && pwd)"

"$script_directory/validate-unsigned-app.sh" "$app_path"
test -d "$sparkle_version_path"
test -f "$extension_entitlements"
test -f "$app_entitlements"

codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$signing_identity" \
    "$sparkle_version_path/XPCServices/Installer.xpc"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --preserve-metadata=entitlements \
    --sign "$signing_identity" \
    "$sparkle_version_path/XPCServices/Downloader.xpc"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$signing_identity" \
    "$sparkle_version_path/Autoupdate"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$signing_identity" \
    "$sparkle_version_path/Updater.app"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$signing_identity" \
    "$sparkle_path"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$extension_entitlements" \
    --sign "$signing_identity" \
    "$quicklook_path"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$extension_entitlements" \
    --sign "$signing_identity" \
    "$thumbnail_path"
codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$app_entitlements" \
    --sign "$signing_identity" \
    "$app_path"
codesign --verify --deep --strict --verbose=4 "$app_path"
