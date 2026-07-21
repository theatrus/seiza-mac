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
                        ├─ Swift SeizaCore ─ C ABI ─ seiza-cabi
SeizaQuickLook.appex ────┘                         ├─ seiza-fits
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

`Rust/seiza-cabi` produces `libseiza_cabi.a` and exports opaque image handles,
borrowed byte buffers, owned UTF-8 strings, and JSON records. No Rust layout,
allocator-owned memory, or panic is allowed to cross the ABI:

- rendered RGBA bytes remain owned by an opaque handle until Swift copies them;
- strings returned to Swift have an explicit `seiza_string_free` function;
- every public operation catches panics and converts failures to an error
  string;
- solution JSON includes the complete WCS matrix and optional SIP terms, not
  only a display summary.

JSON is used for metadata and WCS because those records evolve more often than
the high-volume pixel path. Pixels stay in a direct contiguous buffer.

RGB FITS display rendering exposes three explicit C-ABI modes: per-channel
Auto, Linked Auto with one shared transfer function derived from the average
channel medians and MADs, and Linear native-range mapping. Raster JPEG, PNG,
and TIFF pixels remain color-managed linear display data and are not passed
through the FITS autostretch. Thumbnail cache and background-render job
identities include the RGB stretch mode, so results from different transforms
cannot be accidentally shared.

The main app also exposes catalog readiness and setup through the C ABI. Rust's
verified Seiza download bundles remain the source of dataset manifests and
cached artifacts. Setup reports typed JSON progress to Swift for manifest,
download, SHA-256 verification, installation, and completion phases. The final
materialization pass hashes each complete file while copying it into place, so
the Settings UI continues to show byte-level progress during the otherwise slow
post-download verification step. Catalog setup runs on a utility queue and is
owned by a persistent controller, allowing the Settings window to close without
canceling it. The sandboxed app has outbound-network and user-selected
read/write entitlements; selected directories are retained as security-scoped
bookmarks.

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
distribution. An XCFramework is unnecessary while the C ABI is private to this
repository, but is the clean next step if `seiza-cabi` becomes a separately
distributed SDK.
