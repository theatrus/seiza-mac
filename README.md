# Seiza for Mac

**A native Mac workspace for astronomy images, stacking, and parallax video.**

Open one image or a whole night of captures. Step through them instantly. Stretch
FITS or XISF data, inspect headers, plate-solve a frame, and see the stars and deep-sky
objects in it. Turn a finished image into a camera tour with depth, motion, and
titles. Image processing and video encoding run locally; optional online
stellar-distance lookup sends sky coordinates to astronomical catalogues.

[**Download Seiza for Mac 0.8.0**](https://github.com/theatrus/seiza-mac/releases/latest/download/Seiza-0.8.0-universal.dmg) · [Release notes and other downloads](https://github.com/theatrus/seiza-mac/releases/latest)

**Also from Seiza:** [Core, CLI, and libraries](https://github.com/theatrus/seiza) ·
[Seiza for Windows](https://github.com/theatrus/seiza-win) ·
[FITS and XISF for Photoshop](https://github.com/theatrus/xisf-photoshop)

## See what is in the frame

Press Solve when you want sky context. Seiza draws catalog-colored object
outlines, names, stars, and a WCS grid over the image, while the inspector keeps
the input and display histograms and solve quality visible.

![Seiza displaying a solved narrowband FITS image with catalog outlines, named stars, a WCS grid, paired histograms, and solution quality](docs/images/seiza-solved-overlays.png)

## Review a whole night without leaving the viewer

Open a directory, move through hundreds of mixed FITS, XISF, and raster frames with
the arrow keys, and use cached thumbnails to keep the sequence moving. Stretch
controls stay live over the image and can detach into a persistent panel.

![Seiza browsing a 299-frame FITS directory while editing a live stretch](docs/images/seiza-directory-stretch.png)

[Read the practical guide to browsing, stretching, solving, overlays, and export.](docs/USING-SEIZA.md)

Seiza is a real Mac app built with SwiftUI, AppKit, and the
[Seiza](https://github.com/theatrus/seiza) Rust core. There is no Tauri,
Electron, web view, or local server.

## Features

| Feature | What Seiza does |
| --- | --- |
| FITS, XISF, and raster viewing | Opens FITS, XISF, JPEG, PNG, and TIFF files in native Mac windows. Drop a new file onto any viewer to replace its image. |
| Fast folder review | Browses mixed-format local or network folders without blocking the app, with arrow keys, a thumbnail drawer, a local cache, and nearby-image preloading. |
| Directory stacking | Combines selected FITS or XISF frames into 32-bit floating-point FITS outputs, with optional filename-filter grouping. Choose a reference or let Seiza score the candidates. Set normalization, rejection, registration, frame weighting, interpolation, Bayer processing, and calibration. Use existing masters or build and cache matched masters from raw calibration frames. Track progress and SNR, cancel, and open the saved results. Three-pass transient removal rejects trails left by the live pass. |
| Stacking controls | Similarity, affine, or quadratic registration; global, local, or local-background normalization; equal or bounded inverse-noise-variance weights; bilinear or Lanczos-3 interpolation; VNG, MHC, or bilinear demosaicing; Bayer drizzle; and optional hot/dead pixel suppression. Directory and live stacking share the controls. New modes are opt-in; core defaults stay unchanged. |
| Live folder stacking | Watches a capture folder while an imaging session runs. Seiza waits until each FITS or XISF file stops changing, checks that it is a raw, compatible light frame, and registers it into a filter-locked stack. The live window shows a bounded autostretched preview, accepted and rejected counts, calibration epochs, checkpoint health, and an SNR depth chart. Save a non-destructive FITS snapshot at any time or finish the accumulator into the final 32-bit floating-point stack, which by default makes the same transient-removing pass over the frames. Sessions checkpoint the exact native state: pause, close, or crash, then reopen the window and resume the same accumulator, with the previous complete generation as a fallback after an interrupted write. |
| Astronomy rendering | Displays mono, planar RGB, and Bayer/OSC data through the full-precision Seiza core. Filtered reductions limit noise aliasing in the viewer and previews, while full-resolution images keep crisp source pixels at 1:1 and higher zoom. |
| Live stretch stacks | Adds, removes, reorders, and edits automatic or manual stages. Pick GHS symmetry points from the image, choose linked, per-channel, or luminance-preserving color, copy settings between images, and undo or redo each change. |
| Responsive previews | Renders a quick zoom-aware preview off the main thread, cancels stale work, then replaces it with a source-resolution render. |
| Background correction | Fits automatic, polynomial, or radial-basis gradient models to linear mono or color data. Choose additive subtraction or multiplicative illumination correction, tune the amount, and inspect each change through live preview. |
| Light deconvolution | Applies optional damped Richardson-Lucy restoration with controls for stellar FWHM, strength, noise, and ringing. |
| Image inspection | Fits, zooms, and pans around the pointer; shows source and display histograms; and lets you search or copy image headers. |
| Local plate solving | Solves an image when requested by Solve or a video operation. It sends no image or catalog data off the Mac. |
| Star and tilt measurement | Measures stars in the linear source image without a solve or catalog: HFR, FWHM, SNR, background, and PSF eccentricity per star, with a 3-by-3 sensor grid, corner tilt and field-curvature verdicts, and a triangle sector analysis. Overlays show measured stars, the tilt grid, and off-by-default parallelogram and triangle tilt diagrams in the viewport and composited exports. Verdicts are withheld until every required region holds at least three stars. |
| Sky overlays | Toggles named and field stars, each deep-sky catalog, OpenNGC outlines, transients, comets, asteroids, detections, the coordinate grid, and field center. |
| WCS export | Writes a solved image's linear or SIP solution as a standard header-only FITS `.wcs` sidecar. |
| Catalog setup | Downloads, checks, installs, and repairs solver catalogs in Settings with clear progress and cache reuse. |
| Image export and copy | Exports full-size PNG, JPEG, or TIFF files with optional overlays. PNG and TIFF support 16 bits per channel. Full-size clipboard copy keeps visible overlays. |
| Parallax video | Creates fly-ins and editable multi-stop tours from aligned starless/stars layers, with dolly, pan, zoom, roll, held spins, push, titles and looping. Preview changes without rebuilding the scene, then export H.264 or HEVC MP4 using the Mac's native encoder. |
| Stellar distances | Downloads offline star and object distances from Settings or the video workspace, with verification and progress. Optional online lookup reports its current stage and elapsed time. |
| Finder previews | Shows stretched FITS and XISF thumbnails in Finder. Space-bar Quick Look keeps the full image centered and fitted as the preview changes size, without opening Seiza. |
| Finder file support | Registers `.fits`, `.fit`, `.fts`, and `.xisf` files with a Seiza document icon. |
| Signed in-app updates | Checks for releases on demand or on a user-controlled schedule, then verifies and installs them with Sparkle. |

## Download

[**Download Seiza for Mac 0.8.0**](https://github.com/theatrus/seiza-mac/releases/latest/download/Seiza-0.8.0-universal.dmg), open it, and drag Seiza to Applications.

Or install with [Homebrew](https://brew.sh) from the
[theatrus/homebrew-seiza tap](https://github.com/theatrus/homebrew-seiza):

```sh
brew install --cask theatrus/seiza/seiza-mac
```

Seiza requires macOS 15 or newer. The same download runs natively on Apple
silicon and Intel Macs. Release builds are signed with Developer ID and
notarized by Apple.

## Open FITS and XISF in Photoshop

The separate [FITS and XISF Photoshop plugins](https://github.com/theatrus/xisf-photoshop)
let you open and save astronomy images directly in Photoshop using Seiza's codecs.
Import as Float32 or rescaled 16-bit integer, optionally debayer Bayer mosaics to
RGB, and save at the document's 16- or 32-bit depth by default.

Download the **universal macOS plugin DMG** from the
[latest release](https://github.com/theatrus/xisf-photoshop/releases/latest).
Close Photoshop, open the DMG, and drag both `.plugin` bundles onto the
**Photoshop Plug-ins** shortcut. Approve any administrator prompt, eject the
DMG, and restart Photoshop. The shortcut targets Adobe's shared folder at
`/Library/Application Support/Adobe/Plug-Ins/CC`. Remove older copies from
Photoshop application or custom folders when switching to this location.
If the shared folder is missing, see the
[installation guide](https://github.com/theatrus/xisf-photoshop#macos-installation-dmg).
A ZIP remains available as an alternative. The DMG and bundles support Apple
silicon and Intel and are Developer ID signed, notarized, and stapled.
Configure import defaults under
**Photoshop → About Plug-In → FITS/XISF**.

Starting with plugin 0.5.0, same-format saves retain source headers and metadata;
switching formats copies compatible FITS keywords on a best-effort basis.
Keep your original FITS/XISF files: 16-bit import rescales the image and loses
absolute scale and precision. Re-solve astrometry after geometric edits, and use
PSD/PSB to retain Photoshop layers. See the
[metadata retention limits](https://github.com/theatrus/xisf-photoshop#metadata-retention).

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

The app uses published `seiza-cabi` 0.25.1, `seiza` 0.25.1,
`seiza-parallax` 0.2.1 and `seiza-download` 0.8.0. The renderer includes the
upstream loop-motion and bright-star halo fixes without a local patch. Library
and bridge header must be updated together. About reports the linked release
version and source commit.

## Make a parallax tour

To try parallax video, open an image and choose **File → Parallax Video…** (or
the film toolbar button). Import matching, stretched starless and unscreened
stars PNG/TIFF layers in Source and confirm alignment, or select your installed,
licensed StarXTerminator CLI. Camera offers fly-ins and generated tours, with
editable stops, travel turns, held spins, push, pan, glide, fading titles, looping,
and timing. Prepare the scene once; camera edits automatically refit the preview.
Tours can be saved and loaded as JSON itineraries. Source images and the overall
zoom are not saved in the itinerary. Labels and Output expose annotations, credits, sizing and
native H.264/HEVC MP4 encoding. Plate solving and generated tours need installed
catalogues; offline fields without distance data can use a manual background
distance. Full video-project recovery remains planned. See the
[implementation scope and remaining work](docs/PARALLAX-VIDEO.md).

The app and astronomy document icons are generated from the checked-in colorful
Seiza website mark. Regenerate them on macOS with:

```sh
swift scripts/generate-app-icons.swift
swift scripts/generate-document-icon.swift
```

## Tests and continuous integration

[![CI](https://github.com/theatrus/seiza-mac/actions/workflows/ci.yml/badge.svg)](https://github.com/theatrus/seiza-mac/actions/workflows/ci.yml)

The repository exercises the Rust rendering/C ABI with unit tests and the
native application with XCTest. Every pull request checks Rust formatting and
Clippy warnings, runs both test suites, validates all app and extension property
lists, builds a universal Release application, and verifies an unsigned
development DMG. Pull-request jobs have read-only repository access and never
receive signing secrets.

A push to the official `main` branch runs the same unsigned checks. Only final
release tags enter the protected signing environment and produce signed,
notarized downloads through GitHub Releases.

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
Developer ID sign and notarize the app and DMG, sign the update ZIP, and
publish the appcast, universal DMG, and zipped app to GitHub Releases. See
[RELEASE.md](RELEASE.md) for the complete release runbook and
[docs/RELEASING.md](docs/RELEASING.md) for credential and environment setup.

## Catalogs and solving

Previewing images does not require catalog data. Solving starts when you press
Solve, or when preparing a video or generating a tour without sky coordinates.
Blind solving any supported FITS, XISF, or raster image requires
a complete Seiza catalog directory containing a star catalog and blind index.

Open **Seiza > Settings** (`Command-,`), leave **Standard blind solving**
selected, and click **Download and Install Catalogs**. You can use Seiza's
default data location or choose another writable directory. The Settings pane
reports download, installation, and verification progress and may be closed
while setup continues.

![Seiza catalog download and verification controls in Settings](docs/images/seiza-catalog-setup.jpg)

Downloads are SHA-256 verified into Seiza's immutable cache. Setup then hard
links those verified files into the selected catalog directory when possible,
avoiding the previous second copy and full hash pass. Cross-filesystem installs
fall back to a verified copy. Setup is safe to retry and reuses cached data.

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
`transients.bin` supplies dated transient overlays, and `minor-bodies.bin`
supplies comet and asteroid positions at the image acquisition time. Solving and catalogue loading begin only when requested by Solve or a video operation. If the required star catalog or blind
index is missing, Solve explains the problem and links back to Catalog Settings.
Satellite overlays are intentionally deferred.

For parallax video, Settings also offers **Offline parallax**. The same
download is available in the video's Source inspector and installs stellar
distances, object distances and the object catalogue. Solving catalogues are a
separate package. Online distance lookup is optional and off by default.

## Finder integration

Seiza registers FITS and XISF files and two Quick Look extensions with macOS.
Finder shows stretched image thumbnails in icon, list, column, and Gallery
views. Select a `.fits`, `.fit`, `.fts`, or `.xisf` file and press Space for a
larger preview without opening Seiza. Finder and Quick Look preserve the image
aspect ratio; Quick Look redraws the whole frame to fit whenever its window
changes size.

See the [usage guide](docs/USING-SEIZA.md),
[architecture](docs/ARCHITECTURE.md), and [roadmap](docs/ROADMAP.md).
