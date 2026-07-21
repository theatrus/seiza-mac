# Architecture

## Product boundary

`Seiza.app` is a native SwiftUI/AppKit macOS application. It registers FITS,
JPEG, PNG, and TIFF document types, owns document windows and settings, and
performs expensive work off the main thread. A directory window may contain
any mixture of those formats. `SeizaQuickLook.appex` is a small data-based
Quick Look preview provider for FITS, which macOS does not decode itself. Both
compile the same Swift wrapper and statically link the same Rust C ABI.

```text
Seiza.app ───────────────┐
                        ├─ Swift SeizaCore ─ C ABI ─ upstream seiza-cabi
SeizaQuickLook.appex ────┘                                  ├─ seiza-fits
                                                            ├─ image
                                                            └─ seiza
```

The Quick Look extension only decodes FITS, stretches it, and bounds the output
to a 4096-pixel maximum dimension. It does not open catalogs or plate-solve.
That keeps system previews responsive and isolates catalog access to the main
app. macOS continues to provide its built-in previews for raster formats.

Document-window sessions are owned by the application delegate. Dropping a new
image or directory on an existing viewer replaces that session in place,
retains the window and its normal macOS identity, rekeys duplicate-open
tracking to the new root, and transfers security-scoped access from the old
roots to the new ones.

## C ABI

The app depends on `seiza-cabi` directly from the main Seiza repository.
`Rust/seiza-mac-core` is only a static-link host; it does not copy the C ABI
implementation. It also exports the exact Seiza Git commit selected by
`Cargo.lock` for the About panel. The upstream C ABI exports opaque image
handles, borrowed byte buffers, owned UTF-8 strings, and JSON records. No Rust
layout, allocator-owned memory, or panic is allowed to cross the ABI:

- rendered RGBA8 or native-endian RGBA16 samples remain owned by their distinct
  opaque handles until Swift copies them;
- strings returned to Swift have an explicit `seiza_string_free` function;
- every public operation catches panics and converts failures to an error
  string;
- solution JSON includes the complete WCS matrix and optional SIP terms, not
  only a display summary.

JSON is used for metadata and WCS because those records evolve more often than
the high-volume pixel path. Pixels stay in a direct contiguous buffer.

Display, thumbnail, and Quick Look rendering use only the RGBA8 owner. A 16-bit
PNG or TIFF export makes a separate full-resolution RGBA16 request, converts
the native-endian samples to a byte-order-explicit 64-bit `CGImage`, and lets
ImageIO encode that image without an 8-bit intermediate. JPEG and explicitly
8-bit exports keep using the committed display image. Solve overlays are
rendered as a transparent layer and composited in a 16-bit bitmap context, so
including them does not down-convert the source. This boundary is based on the
rendered pixels rather than the source extension, allowing another supported
high-depth input such as XISF to reuse it.

FITS display rendering sends a non-empty, ordered stack of validated stretch
configurations to the C ABI. Rust keeps intermediate stage data in `f32` and
only converts the final result to RGBA, so the Swift undo/redo history never
introduces 8-bit interstage quantization. The toolbar groups automatic MTF and
percentile Asinh separately from manual Linear, Asinh, MTF, and Generalized
Hyperbolic Stretch controls, with an identity option for normalized data. GHS
can sample its symmetry point from the displayed image. Color FITS can analyze
linked or per-channel data, or stretch luminance while preserving RGB
chromaticity. An optional background step fits and subtracts a smooth model
from the linear mono or RGB samples. Optional deconvolution then applies
conservative damped Richardson–Lucy restoration with a caller-supplied stellar
PSF FWHM before the first stretch stage. Both operations remain on linear `f32`
pixels inside Seiza; Swift never round-trips them through an 8-bit display image.

The Swift editor owns one draft stack independently from its presentation. The
toolbar opens that editor as a bounded popover by default; a pop-out action
hosts the same view, bindings, validation, and preview callbacks in a resizable
AppKit utility panel. Adding, removing, selecting, or reordering a stage mutates
the shared draft and schedules the same live-preview path. Saving replaces the
committed stack as one undoable history operation. The panel closes when its
document changes or disappears, so it cannot keep editing a stale image model.

Interactive controls debounce edits and submit them to a serial latest-only
preview queue. Pending work is cancelled when a newer edit arrives; a native
render already inside the C ABI may finish, but its result is discarded. Only
the newest result can update the document. The preview is bounded to 2048
pixels while the committed full-resolution render remains separate for export,
and source dimensions from metadata keep zoom and overlay geometry stable while
the preview is visible. The C ABI retains the two most recent prepared linear
preview buffers, keyed by file identity, preview size, and background settings.
Stretch and deconvolution edits therefore reuse the decoded, downsampled, and
(when enabled) background-corrected pixels instead of refitting the same
background. Deconvolution reruns from that cached linear base when its controls
change. Its source-pixel PSF FWHM is scaled to the bounded preview dimensions;
the committed render uses the original value at full resolution.

Raster JPEG, PNG, and TIFF pixels remain color-managed display data and bypass
the FITS stretch pipeline. Thumbnail-cache and background-render job identities
include the complete, deterministically encoded processing request, so only
truly identical stretch, background, and deconvolution renders share work or
cached pixels.

The ABI supplies exact 256-bin channel counts for input and rendered pixels.
The inspector plots those counts on a linear vertical scale capped at the 98th
percentile of populated interior bins. This keeps normal image structure
readable without letting clipped black/white endpoints or a single hot bin
flatten the rest of the chart.

The main app also exposes catalog readiness and setup through the C ABI. Rust's
verified Seiza download bundles remain the source of dataset manifests and
cached artifacts. Setup reports typed JSON progress to Swift for manifest,
download, SHA-256 verification, installation, and completion phases. Catalog
materialization uses the download crate's immutable cache directly: it hard
links verified cache objects into the configured directory on the same file
system, avoiding a second copy and hash pass, and falls back to a verified copy
across file systems. Catalog setup runs on a utility queue and is owned by a
persistent controller, allowing the Settings window to close without canceling
it. The sandboxed app has outbound-network and user-selected read/write
entitlements; selected directories are retained as security-scoped bookmarks.

## Data and provenance

The app keeps these values distinct:

- original source format and, when present, FITS headers;
- derived display pixels and stretch settings;
- detected image stars;
- a solved WCS with solver quality and elapsed time;
- coordinate-only catalog associations and overlay availability, counts, and
  unavailable reasons;
- acquisition timestamps used to classify transients and calculate minor-body
  positions.

A catalog association is never represented as proof that an object is visible
in the pixels. The solve response preserves stable object identity, catalog
source, sky coordinates, transient discovery date/proximity, and minor-body
distance and motion independently from pixel detections. Future saved sidecars
should include input file identity, Seiza version, catalog/index identity,
solve parameters, and WCS/SIP output.

The main catalog supplies deep-sky objects and named stars. Transients and
minor bodies are opened from their dedicated catalog files only after an
explicit solve. Minor-body coordinates are calculated for the FITS acquisition
time and are unavailable when no usable timestamp exists. Satellite prediction
is outside the current application boundary.

## Distribution

Debug builds compile the host architecture. Release builds can pass both
`arm64 x86_64` in `ARCHS`; `scripts/build-rust.sh` creates the two Rust slices
and combines them with `lipo`. The resulting app and embedded extension need a
single signing team, hardened runtime, notarization, and normal macOS app
distribution. Cargo builds the pinned upstream ABI directly, so an XCFramework
is unnecessary for the current source-based integration.
