#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 APP_PATH" >&2
    exit 64
fi

app_path="$1"
plugins_path="$app_path/Contents/PlugIns"
quicklook_path="$plugins_path/SeizaQuickLook.appex"
thumbnail_path="$plugins_path/SeizaThumbnail.appex"
sparkle_path="$app_path/Contents/Frameworks/Sparkle.framework"

test -d "$plugins_path"
test -d "$quicklook_path"
test -d "$sparkle_path"

while IFS= read -r symlink_path; do
    case "$symlink_path" in
        "$sparkle_path"/*) ;;
        *)
            echo "unexpected symlink outside Sparkle.framework: $symlink_path" >&2
            exit 1
            ;;
    esac

    symlink_target="$(readlink "$symlink_path")"
    case "$symlink_target" in
        /*|../*|*/../*|*/..)
            echo "unsafe Sparkle symlink target: $symlink_path -> $symlink_target" >&2
            exit 1
            ;;
    esac
done < <(find "$app_path" -type l -print)

while IFS= read -r extension_path; do
    case "$extension_path" in
        "$quicklook_path"|"$thumbnail_path") ;;
        *)
            echo "unexpected app extension: $extension_path" >&2
            exit 1
            ;;
    esac
done < <(find "$plugins_path" -mindepth 1 -maxdepth 1 -print)

test "$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")" = "fyi.seiza.mac"
test "$(plutil -extract CFBundleIdentifier raw "$quicklook_path/Contents/Info.plist")" = "fyi.seiza.mac.quicklook"
test "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$quicklook_path/Contents/Info.plist")" = "com.apple.quicklook.preview"
test "$(plutil -extract CFBundleShortVersionString raw "$sparkle_path/Resources/Info.plist")" = "2.9.4"
file "$app_path/Contents/MacOS/Seiza" \
    | grep -q 'universal binary with 2 architectures'
file "$quicklook_path/Contents/MacOS/SeizaQuickLook" \
    | grep -q 'universal binary with 2 architectures'

if [ -e "$thumbnail_path" ]; then
    test -d "$thumbnail_path"
    test "$(plutil -extract CFBundleIdentifier raw "$thumbnail_path/Contents/Info.plist")" = "fyi.seiza.mac.thumbnail"
    test "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$thumbnail_path/Contents/Info.plist")" = "com.apple.quicklook.thumbnail"
    file "$thumbnail_path/Contents/MacOS/SeizaThumbnail" \
        | grep -q 'universal binary with 2 architectures'
fi
