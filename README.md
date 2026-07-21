# Seiza for macOS

[![CI](https://github.com/theatrus/seiza-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/theatrus/seiza-mac/actions/workflows/ci.yml)

[**Download Seiza 0.2.0 for macOS**](https://github.com/theatrus/seiza-mac/releases/latest/download/Seiza-0.2.0-universal.dmg) · [Release notes, ZIP, and checksums](https://github.com/theatrus/seiza-mac/releases/latest)

Universal for Apple silicon and Intel. Requires macOS 15 or later. Developer ID
signed, notarized by Apple, and bundled with a FITS Quick Look extension.

![Seiza browsing an astronomy-image folder with its thumbnail drawer](docs/images/seiza-gallery.jpg)

![Seiza displaying a plate-solved FITS image with a WCS grid, field center, and catalog overlays](docs/images/seiza-solved-fits.jpg)

A fast, native macOS astronomy-image viewer and plate-solving app powered by the
[Seiza](https://github.com/theatrus/seiza) Rust libraries. There is no Tauri,
web view, or local server in the application path: SwiftUI and AppKit own the
macOS experience, and a small `seiza-cabi` static library owns the Rust FFI.

The initial app already provides:

- native file/folder opening and drag-and-drop for FITS, JPEG, PNG, and TIFF,
  including replacing the contents of an existing viewer window;
- naturally sorted, mixed-format folder collections with a thumbnail drawer,
  toolbar controls, and Left/Right Arrow navigation;
- persistent local thumbnail caching with parallel, system-scheduled tile renders
  and instant previews while full-resolution images load in the background;
- mono, planar-RGB, and Bayer/OSC rendering through `seiza-fits`;
- color-preserving JPEG, PNG, and TIFF decoding through Seiza's `image` pipeline;
- selectable per-channel Auto, color-preserving Linked Auto, and Linear display
  modes for planar-RGB and Bayer/OSC FITS, using the N.I.N.A./PixInsight-family
  MTF for automatic stretches;
- FITS header and image-statistics inspection;
- asynchronous, explicitly requested blind solving through Seiza 0.11.2;
- in-app catalog download, installation, repair, and readiness checks with
  byte-level progress through the complete SHA-256 verification phase;
- Seiza Server-parity solve overlays for named stars, individually toggleable
  deep-sky catalogs, current and historical transients, acquisition-time
  comets and asteroids, field stars, a coordinate grid, field center, and
  diagnostic detections, using the catalog-aware palette and restrained SVG
  styling from `@seiza/astro-overlay` 0.5;
- detailed OpenNGC contours with catalog ellipses as the fallback, plus
  independent object-label and outline controls;
- a data-based Quick Look preview extension bundled inside the app;
- a dedicated HIG-style FITS document icon for Finder and Open With
  associations.

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

The app and FITS document icons are generated from the checked-in colorful
Seiza website mark. Regenerate them on macOS with:

```sh
swift scripts/generate-app-icons.swift
swift scripts/generate-document-icon.swift
```

## Tests and continuous integration

The repository exercises the Rust rendering/C ABI with unit tests and the
native application with XCTest. Main-branch CI checks Rust formatting and
Clippy warnings, runs both test suites, validates the app and extension property
lists, builds a universal Release application, packages an unsigned development
DMG, and asks macOS to verify the resulting disk image. Pull requests do not run
automatically; after owner review, an owner-dispatched workflow builds a signed,
notarized DMG from the exact approved commit for iteration.

```sh
cargo test --workspace --locked
xcodebuild test \
  -project Seiza.xcodeproj \
  -scheme Seiza \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Tags matching `vMAJOR.MINOR.PATCH` enter the protected `signing` environment,
Developer ID sign and notarize the app and DMG, and publish the universal DMG
and zipped app to GitHub Releases. See [RELEASE.md](RELEASE.md) for the complete
release runbook and [docs/RELEASING.md](docs/RELEASING.md) for credential and
environment setup.

## Catalogs and solving

Previewing images does not require catalog data, and Seiza never starts a solve
until you press Solve. Blind solving any supported FITS or raster image requires
a complete Seiza catalog directory containing a star catalog and blind index.

Open **Seiza > Settings** (`Command-,`), leave **Standard blind solving**
selected, and click **Download and Install Catalogs**. You can use Seiza's
default data location or choose another writable directory. The Settings pane
reports download, installation, and verification progress and may be closed
while setup continues.

![Seiza catalog download and verification controls in Settings](docs/images/seiza-catalog-setup.jpg)

After the transfer finishes, Seiza reads every large catalog from beginning to
end to verify its SHA-256 digest. This phase can take several minutes, but its
byte counter continues to report progress. Setup is safe to retry and will
reuse already verified downloads.

The equivalent command-line setup is:

```sh
seiza setup
```

or:

```sh
seiza download-data prebuilt --output /path/to/catalogs
```

If you created a catalog directory on the command line, choose that directory
in Seiza's Settings. The sandbox permission is retained as a security-scoped
bookmark. The main object catalog supplies named-star and deep-sky overlays,
`transients.bin`
supplies dated transient overlays, and `minor-bodies.bin` supplies comet and
asteroid positions at the FITS acquisition time. Solving and catalog loading
only begin when the user presses Solve. If the required star catalog or blind
index is missing, Solve explains the problem and links back to Catalog Settings.
Satellite overlays are intentionally deferred.

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
