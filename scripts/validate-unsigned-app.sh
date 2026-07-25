#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 APP_PATH" >&2
    exit 64
fi

app_path="$1"
quicklook_path="$app_path/Contents/PlugIns/SeizaQuickLook.appex"
sparkle_path="$app_path/Contents/Frameworks/Sparkle.framework"

test -d "$quicklook_path"
test -d "$sparkle_path"
test "$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")" = "fyi.seiza.mac"
test "$(plutil -extract CFBundleIdentifier raw "$quicklook_path/Contents/Info.plist")" = "fyi.seiza.mac.quicklook"
test "$(plutil -extract CFBundleShortVersionString raw "$sparkle_path/Resources/Info.plist")" = "2.9.4"
file "$app_path/Contents/MacOS/Seiza" \
    | grep -q 'universal binary with 2 architectures'

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
