# Seiza for macOS

[![CI](https://github.com/theatrus/seiza-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/theatrus/seiza-mac/actions/workflows/ci.yml)

A fast, native macOS astronomy-image viewer and plate-solving app powered by the
[Seiza](https://github.com/theatrus/seiza) Rust libraries. There is no Tauri,
web view, or local server in the application path: SwiftUI and AppKit own the
macOS experience, and a small `seiza-cabi` static library owns the Rust FFI.

The initial app already provides:

- native file/folder opening and drag-and-drop for FITS, JPEG, PNG, and TIFF;
- naturally sorted, mixed-format folder collections with a thumbnail drawer,
  toolbar controls, and Left/Right Arrow navigation;
- persistent local thumbnail caching with parallel, system-scheduled tile renders
  and instant previews while full-resolution images load in the background;
- mono, planar-RGB, and Bayer/OSC rendering through `seiza-fits`;
- color-preserving JPEG, PNG, and TIFF decoding through Seiza's `image` pipeline;
- N.I.N.A./PixInsight-family MTF autostretch;
- FITS header and image-statistics inspection;
- asynchronous, explicitly requested blind solving through Seiza 0.11.2;
- independently toggled deep-sky object, object-label, field-center, and
  diagnostic star overlays projected through the solved WCS, using the
  catalog-aware palette and restrained SVG styling from
  `@seiza/astro-overlay` 0.5, including detailed OpenNGC contours with catalog
  ellipses as the fallback;
- a data-based Quick Look preview extension bundled inside the app.

## Build

Requirements: macOS 15 or newer, Xcode 26, Rust 1.89 or newer, and the Rust
target matching the Mac being built.

```sh
cargo test --workspace
xcodebuild \
  -project Seiza.xcodeproj \
  -scheme Seiza \
  -configuration Debug \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The unsigned development app is written to:

```text
DerivedData/Build/Products/Debug/Seiza.app
```

Open `Seiza.xcodeproj` to run and sign it with a local development team.

## Tests and continuous integration

The repository exercises the Rust rendering/C ABI with unit tests and the
native application with XCTest. CI checks Rust formatting and Clippy warnings,
runs both test suites, validates the app and extension property lists, builds a
universal Release application, packages an unsigned development DMG, and asks
macOS to verify the resulting disk image.

```sh
cargo test --workspace --locked
xcodebuild test \
  -project Seiza.xcodeproj \
  -scheme Seiza \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Tags matching `vMAJOR.MINOR.PATCH` publish a universal DMG and zipped app to
GitHub Releases. Until the Apple credentials are installed, releases are
clearly marked as unsigned development previews. See
[docs/RELEASING.md](docs/RELEASING.md) for the notarization handoff.

## Catalogs and solving

Previewing images does not require catalog data. Blind solving any supported
FITS or raster image requires a
complete Seiza catalog directory containing a star catalog and blind index.
Create one with either:

```sh
seiza setup
```

or:

```sh
seiza download-data prebuilt --output /path/to/catalogs
```

Choose that directory in Seiza's Settings. The sandbox permission is retained
as a security-scoped bookmark; the app does not copy the catalog.

## Quick Look and Preview.app

The bundled Quick Look extension is the supported modern macOS integration
for custom previews. Once the signed app is installed, it makes stretched FITS
previews available to system Quick Look clients for the registered FITS type.
Apple documents Quick Look preview extensions, but does not expose a modern
third-party decoder plug-in API for Preview.app itself. Direct “Open in
Preview” handoff can be added by rendering a temporary TIFF or PNG; making
Preview.app decode the original FITS file in-process is intentionally not part
of this design.

Finder image thumbnails are a separate `QLThumbnailProvider` extension and are
deliberately left for the next phase.

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) and [ROADMAP.md](docs/ROADMAP.md).
