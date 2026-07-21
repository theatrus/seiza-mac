#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 /path/to/Seiza.app /path/to/output.dmg version" >&2
  exit 2
fi

app_path="$1"
output_path="$2"
version="$3"

if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
  echo "application bundle not found: $app_path" >&2
  exit 1
fi

output_directory="$(dirname "$output_path")"
mkdir -p "$output_directory"
output_path="$(cd "$output_directory" && pwd)/$(basename "$output_path")"

staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/seiza-dmg.XXXXXX")"
cleanup() {
  rm -rf "$staging_directory"
}
trap cleanup EXIT

ditto "$app_path" "$staging_directory/Seiza.app"
ln -s /Applications "$staging_directory/Applications"
hdiutil create \
  -volname "Seiza $version" \
  -srcfolder "$staging_directory" \
  -format UDZO \
  -ov \
  "$output_path"
