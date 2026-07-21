# Roadmap

## Current state

The native viewer foundation is complete on `main`. The public v0.3.0 release
contains the core viewer, folder workflow, explicit solving, catalog setup,
catalog overlays, document icons, and the first Quick Look extension. Feature
work merged after v0.3.0 repairs Finder Quick Look, adds paired histograms and
image export, adopts the upstream `seiza-cabi` crate and faster catalog
installer, reports the exact linked core version, and adds full-precision
stackable stretch controls with undo/redo and image-picked GHS symmetry points.

That post-v0.3.0 work is on `main`, has passed unsigned PR CI and universal DMG
packaging, and is not yet a versioned public release. Phase 2 is the next product
focus.

## Phase 1 — native viewer foundation (complete on `main`)

- FITS/JPEG/PNG/TIFF document registration, mixed-format directories, and
  multi-window opening
- parameterized Auto MTF, percentile Asinh, Linear, Asinh, MTF, GHS, and
  identity display modes with linked, per-channel, and luminance-preserving
  color handling for planar-RGB and OSC/Bayer images; additive stage history,
  undo/redo, and image-picked GHS symmetry points
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

## Phase 2 — serious inspection (next)

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
