#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${CONFIGURATION:-Debug}"
profile_directory="debug"
if [[ "$configuration" != "Debug" ]]; then
  profile_directory="release"
fi

output_directory="$repository_root/.build/rust/$configuration"
mkdir -p "$output_directory"
architectures="${ARCHS:-${NATIVE_ARCH_ACTUAL:-$(uname -m)}}"
slices=()

for architecture in $architectures; do
  case "$architecture" in
    arm64) rust_target="aarch64-apple-darwin" ;;
    x86_64) rust_target="x86_64-apple-darwin" ;;
    *) echo "Unsupported architecture: $architecture" >&2; exit 1 ;;
  esac

  cargo_arguments=(
    build
    --manifest-path "$repository_root/Cargo.toml"
    --package seiza-mac-core
    --target "$rust_target"
  )
  if [[ "$configuration" != "Debug" ]]; then
    cargo_arguments+=(--release)
  fi
  cargo "${cargo_arguments[@]}"
  slices+=("$repository_root/target/$rust_target/$profile_directory/libseiza_mac_core.a")
done

if [[ "${#slices[@]}" -eq 1 ]]; then
  cp "${slices[0]}" "$output_directory/libseiza_mac_core.a"
else
  xcrun lipo -create "${slices[@]}" -output "$output_directory/libseiza_mac_core.a"
fi
