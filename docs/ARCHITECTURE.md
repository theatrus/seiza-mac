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

## Data and provenance

The app keeps these values distinct:

- original source format and, when present, FITS headers;
- derived display pixels and stretch settings;
- detected image stars;
- a solved WCS with solver quality and elapsed time;
- future coordinate-only catalog associations and overlays.

A catalog association will never be represented as proof that an object is
visible in the pixels. Future saved sidecars should include input file identity,
Seiza version, catalog/index identity, solve parameters, and WCS/SIP output.

## Distribution

Debug builds compile the host architecture. Release builds can pass both
`arm64 x86_64` in `ARCHS`; `scripts/build-rust.sh` creates the two Rust slices
and combines them with `lipo`. The resulting app and embedded extension need a
single signing team, hardened runtime, notarization, and normal macOS app
distribution. An XCFramework is unnecessary while the C ABI is private to this
repository, but is the clean next step if `seiza-cabi` becomes a separately
distributed SDK.
