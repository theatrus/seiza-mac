# Roadmap

## Phase 1 — native viewer foundation

- FITS/JPEG/PNG/TIFF document registration, mixed-format directories, and
  multi-window opening
- parameterized Auto MTF, percentile Asinh, Linear, Asinh, MTF, GHS, and
  identity display modes with linked, per-channel, and luminance-preserving
  color handling for planar-RGB and OSC/Bayer images
- header/statistics inspector with paired pre- and post-stretch RGB or luminance histograms
- blind solve action with security-scoped catalog selection
- catalog-colored, independently toggleable solve overlays for named stars,
  deep-sky catalogs and OpenNGC contours, transients, acquisition-time comets
  and asteroids, field stars, coordinate grid, labels, and field center
- HIG-style FITS document icon and Quick Look preview extension
- source-resolution PNG, JPEG, and TIFF export with optional visible solve overlays
- signed, notarized Apple-silicon development distribution
- managed, retry-safe catalog download and repair UI with readiness checks and
  verified-cache, hard-link-aware installation progress

## Phase 2 — serious inspection

- pixel loupe, black/midtone controls, and finer stretch controls
- star-detection overlays and measured HFR/FWHM
- compass, scale bar, and WCS cursor readout
- hinted solving from FITS headers before blind-solving fallback
- cancellation and in-process catalog/index caching
- sidecar export with typed provenance and FITS WCS card export

## Phase 3 — system integration

- `QLThumbnailProvider` Finder thumbnails
- Spotlight metadata importer for selected FITS headers
- Finder Quick Actions for solve and export

## Phase 4 — the whole works

- sequence browsing and rapid next/previous frame comparison
- blink/difference views and registration
- satellite overlays with shutter-open time, observer, element epoch, and
  explicit prediction provenance
- multi-extension FITS image-HDU navigation
- lazy FITS cube slice navigation with neighboring-slice preloading
- catalog bundle update discovery and selective dataset management
- universal signed releases, updater, crash reporting, and performance corpus
