# Roadmap

## Current state

Seiza 0.4.0 completes the native viewer base. It opens FITS, XISF, and raster
images; browses mixed folders; renders full-precision stretch stacks; removes
background gradients; applies optional light deconvolution; solves on demand;
draws catalog overlays; exports images and WCS data; and previews FITS and XISF
files through Finder Quick Look. The app also has paired histograms, cached
thumbnails, full-size clipboard copy, 16-bit PNG and TIFF export, and managed
catalog setup.

## Phase 1 — native viewer foundation (complete in 0.4.0)

- FITS/XISF/JPEG/PNG/TIFF document registration, mixed-format directories, and
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
- HIG-style astronomy document icon and FITS/XISF Quick Look preview extension
- source-resolution 8- or 16-bit PNG and TIFF export and 8-bit JPEG export,
  with optional visible solve overlays
- signed and notarized universal Apple-silicon/Intel distribution with
  protected CI signing
- managed, retry-safe catalog download and repair UI with readiness checks and
  verified-cache, hard-link-aware installation progress

## Phase 2 — serious inspection (in progress)

- pixel loupe, black/midtone controls, and finer stretch controls
- star-detection overlays and measured HFR/FWHM
- compass, scale bar, and WCS cursor readout
- hinted solving from FITS headers before blind-solving fallback
- cancellation and in-process catalog/index caching
- typed solve provenance sidecars

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
