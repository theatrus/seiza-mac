#!/bin/bash
# Embed the Apple silicon runtime only. The universal app loads it on demand.
set -euo pipefail
cache="$SRCROOT/.build/onnxruntime"
frameworks="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
notices="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ONNXRuntime"
mkdir -p "$cache" "$frameworks" "$notices"
stage="$(mktemp -d "$cache/embed.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

archive() {
    local name="$1" sha="$2" url="$3"
    if ! (cd "$cache" && echo "$sha  $name" | shasum -a 256 -c --status) 2>/dev/null; then
        curl -fLsS --retry 3 "$url" -o "$stage/$name"
        (cd "$stage" && echo "$sha  $name" | shasum -a 256 -c -)
        mv "$stage/$name" "$cache/$name"
    fi
}
arm=onnxruntime-osx-arm64-1.31.1
archive "$arm.tgz" 2e1344a1926ee50eb25b38153cb6992c3567515aef0e677a1a520a1798896d6f \
    "https://github.com/theatrus/psf-guard/releases/download/onnxruntime-1.31.1/$arm.tgz"
tar -xzf "$cache/$arm.tgz" -C "$stage" "$arm/lib/libonnxruntime.1.31.1.dylib" "$arm/LICENSE" "$arm/ThirdPartyNotices.txt"
cp "$stage/$arm/LICENSE" "$stage/$arm/ThirdPartyNotices.txt" "$notices/"
library="$stage/$arm/lib/libonnxruntime.1.31.1.dylib"
xcrun lipo -verify_arch arm64 "$library"
install -m 755 "$library" "$frameworks/libonnxruntime.dylib"
