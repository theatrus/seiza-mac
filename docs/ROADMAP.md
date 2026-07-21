# Roadmap

## Current state

The native viewer foundation is complete on `main`. The public v0.3.0 release
contains the core viewer, folder workflow, explicit solving, catalog setup,
catalog overlays, document icons, and the first Quick Look extension. Feature
work merged after v0.3.0 repairs Finder Quick Look, adds paired histograms and
image export, adopts the upstream `seiza-cabi` crate and faster catalog
installer, reports the exact linked core version, and adds full-precision
stackable stretch controls with undo/redo, image-picked GHS symmetry points,
latest-only live previews, optional smooth background-gradient removal,
in-place add/remove/reorder controls, and a detachable utility panel.

Active [PR #13](https://github.com/theatrus/seiza-mac/pull/13) adds optional
conservative deconvolution after background correction and before stretching.
The Mac controls expose measured PSF FWHM,
iterations, amount, noise damping, and correction limits without enabling the
operation by default. Merged [Seiza PR #76](https://github.com/theatrus/seiza/pull/76)
composes that step inside the native linear FITS render pipeline and preserves
the cached background-prepared preview across deconvolution edits.

## Phase 1 — native viewer foundation (complete on `main`)

- FITS/JPEG/PNG/TIFF document registration, mixed-format directories, and
  multi-window opening
- parameterized Auto MTF, percentile Asinh, Linear, Asinh, MTF, GHS, and
  identity display modes with linked, per-channel, and luminance-preserving
  color handling for planar-RGB and OSC/Bayer images; additive stage history,
  undo/redo, image-picked GHS symmetry points, live draft-stack editing, stage
  removal/reordering, latest-only previews, optional linear background-gradient
  removal, and a detachable utility panel
- header/statistics inspector with paired pre- and post-stretch RGB or luminance histograms
- blind solve action with security-scoped catalog selection
- catalog-colored, independently toggleable solve overlays for named stars,
  deep-sky catalogs and OpenNGC contours, transients, acquisition-time comets
  and asteroids, field stars, coordinate grid, labels, and field center
- HIG-style FITS document icon and Quick Look preview extension
- source-resolution PNG, JPEG, and TIFF export with optional visible solve overlays
- signed and notarized universal Apple-silicon/Intel distribution with
  protected CI signing
- managed, retry-safe catalog download and repair UI with readiness checks and
  verified-cache, hard-link-aware installation progress

## Phase 2 — serious inspection (in progress)

- optional conservative stellar deconvolution with live bounded previews
- pixel loupe, black/midtone controls, and finer stretch controls
- star-detection overlays and measured HFR/FWHM
- compass, scale bar, and WCS cursor readout
- hinted solving from FITS headers before blind-solving fallback
- cancellation and in-process catalog/index caching
- sidecar export with typed provenance and FITS WCS card export

## Phase 3 — system integration (later)

- `QLThumbnailProvider` Finder thumbnails
- Spotlight metadata importer for selected FITS headers
- Finder Quick Actions for solve and export

## Phase 4 — the whole works (long term)

- high-rate sequence review, blink/difference views, and registration
- satellite overlays with shutter-open time, observer, element epoch, and
  explicit prediction provenance
- multi-extension FITS image-HDU navigation
- lazy FITS cube slice navigation with neighboring-slice preloading
- catalog bundle update discovery and selective dataset management
- automatic updates, crash reporting, and a performance regression corpus
