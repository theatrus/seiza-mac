# Architecture

## Product boundary

`Seiza.app` is a native SwiftUI/AppKit macOS application. It registers FITS,
XISF, JPEG, PNG, and TIFF document types, owns document windows and settings, and
performs expensive work off the main thread. A directory window may contain
any mixture of those formats. `SeizaQuickLook.appex` provides full Quick Look
previews for FITS and XISF, which macOS does not decode itself.
`SeizaThumbnail.appex` provides their Finder content thumbnails. All three
targets compile the same Swift wrapper and statically link the same Rust C ABI.

```text
Seiza.app ───────────────┐
                        ├─ Swift SeizaCore ─ C ABI ─ upstream seiza-cabi
SeizaQuickLook.appex ────┤                                  ├─ seiza-fits
SeizaThumbnail.appex ────┘                                  ├─ seiza-xisf
                                                            ├─ image
                                                            └─ seiza
```

The Quick Look extensions only decode FITS or XISF, stretch it, and bound the
output. The preview extension uses a 4096-pixel maximum dimension. The
thumbnail extension matches each Finder request and caps work at 4096 pixels.
Neither opens catalogs nor plate-solves. This keeps system previews responsive
and leaves catalog access in the main app. macOS keeps its built-in previews
for raster formats.

Document-window sessions are owned by the application delegate. Dropping a new
image or directory on an existing viewer replaces that session in place,
retains the window and its normal macOS identity, rekeys duplicate-open
tracking to the new root, and transfers security-scoped access from the old
roots to the new ones.

## C ABI

The app depends on the published `seiza-cabi` crate from crates.io.
`Rust/seiza-mac-core` is only a static-link host; it does not copy the C ABI
implementation. It reads Cargo's VCS metadata from the published crate and
exports its exact Seiza Git commit for the About panel. The upstream C ABI
exports opaque image handles, borrowed byte buffers, owned UTF-8 strings, and
JSON records. No Rust layout, allocator-owned memory, or panic is allowed to
cross the ABI:

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

FITS and XISF display rendering sends a non-empty, ordered stack of validated stretch
configurations to the C ABI. Rust keeps intermediate stage data in `f32` and
only converts the final result to RGBA, so the Swift undo/redo history never
introduces 8-bit interstage quantization. The toolbar groups automatic MTF and
percentile Asinh separately from manual Linear, Asinh, MTF, and Generalized
Hyperbolic Stretch controls, with an identity option for normalized data. GHS
can sample its symmetry point from the displayed image. Color FITS and XISF can analyze
linked or per-channel data, or stretch luminance while preserving RGB
chromaticity. An optional background step fits an automatic, polynomial, or
radial-basis surface to the linear mono or RGB samples, then applies additive
or multiplicative correction at the requested strength. Optional deconvolution
then applies conservative damped Richardson–Lucy restoration with a
caller-supplied stellar PSF FWHM before the first stretch stage. Both operations
remain on linear `f32` pixels inside Seiza; Swift never round-trips them through
an 8-bit display image.

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
the astronomy stretch pipeline. Thumbnail-cache and background-render job identities
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

## Frame stacking and live sessions

Directory stacking and live folder stacking share one native accumulator: the
C ABI's live stacker owns registration, calibration, frame-to-frame
normalization, rejection state, and the accepted/rejected counters. Swift
never touches pixel math. Header classification, calibration planning, and
frame admission all cross the ABI as versioned JSON (`seiza_probe_frame_json`,
`seiza_calibration_plan_json`, `seiza_calibration_build_master_json`) rather
than being reimplemented in Swift.

Automatic calibration preparation probes a raw library, asks the native
planner for one coherent selection per kind that satisfies every target light,
and builds bias, dark, dark-flat, and flat masters in dependency order. The
dark-flat is an internal intermediate: the service builds it with the
native `dark` kind and consumes it only as the flat's pedestal reference. Without a bias, Seiza
withholds the flat unless an uncalibrated dark-flat or dark with a known
exposure matches every selected flat, and re-probes a freshly built flat so
its written metadata must still match every target. Masters live under
`Application Support/Seiza/CalibrationMasters/<library-id>` keyed by a SHA-256
fingerprint over the native kind, core version, build options, upstream
master fingerprints, and each input's path, size, and timestamp. `flock`-based
lock and retain leases let concurrent preparations share builds and keep
pruning (8 GiB / 30 days) away from masters still in use.

Live sessions live under `Application Support/Seiza/LiveStacks/<folder-id>`.
The folder monitor enumerates the capture folder on a short interval; a file
becomes a candidate only after two observations spanning a stability window
with the same size, timestamp, and `(device, inode)` identity, so renames and
hard links never stack twice and files still being written are never opened.
Admission gates run in order: role must be `light`, a configured master set
requires a raw unprocessed light, the locked filter must match, and the
camera/geometry signature must match the reference. Checkpoints publish a
generation pair — an opaque native context from
`seiza_live_stacker_save_context` plus a JSON manifest holding the app-owned
ledger, calibration epochs, SNR samples, and the expected native state — and
flip a pointer file, keeping the previous complete generation as a fallback.
Resume reopens the context, verifies it describes the manifest's checkpoint,
and re-derives the reference identity before admitting new lights. Three
invariants hold throughout: a successful native push is always followed by a
non-cancellable ledger update; every native mutation that changes resumable
meaning is followed by a forced checkpoint; and a completed session is retired
only after its final export is on disk.

SNR analysis reads the accumulator through `seiza_live_stacker_measure_depth`
at doubling depths (plus the final depth). Depth comparisons divide the
deepest measured signal by each depth's noise, because the per-reading
signal-to-noise flatters shallow stacks; the depth chart plots that relative
SNR against the square-root ideal anchored at the shallowest point. Live
previews render natively from the physical linear mean through a
robust-percentile sample-domain mapping before the display stretch.

## Data and provenance

The app keeps these values distinct:

- original source format and, when present, astronomy image headers;
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
explicit solve. Minor-body coordinates are calculated for the image acquisition
time and are unavailable when no usable timestamp exists. Satellite prediction
is outside the current application boundary.

## Distribution

Debug builds compile the host architecture. Release builds can pass both
`arm64 x86_64` in `ARCHS`; `scripts/build-rust.sh` creates the two Rust slices
and combines them with `lipo`. The resulting app and embedded extension need a
single signing team, hardened runtime, notarization, and normal macOS app
distribution. Cargo builds the locked crates.io ABI directly, so an
XCFramework is unnecessary for the current source-based integration.
