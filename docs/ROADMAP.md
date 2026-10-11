# Roadmap

## Current state

Seiza for Mac 0.4.0 completes the native viewer base. It opens FITS, XISF, and raster
images; browses mixed folders; renders full-precision stretch stacks; removes
background gradients; applies optional light deconvolution; solves on demand;
draws catalog overlays; exports images and WCS data; and renders FITS and XISF
thumbnails and previews in Finder. The app also has paired histograms, cached
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
- HIG-style astronomy document icon plus FITS/XISF Finder thumbnails and Quick
  Look previews
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

- Spotlight metadata importer for selected FITS headers
- Finder Quick Actions for solve and export

## In progress — parallax video

The [parallax video workspace](PARALLAX-VIDEO.md) integrates imported pairs or
an optional licensed separator, fly-ins, generated/editable tours, saved tour
JSON, scene reuse, automatic camera previews, labels, and native H.264/HEVC
export. Tour stops expose roll, pan, spin, push, zoom, and independent travel/hold
timing, with global glide. The merged
[seiza#240](https://github.com/theatrus/seiza/pull/240) is consumed through
published C ABI 0.25.0, with a temporary renderer patch from
[seiza#242](https://github.com/theatrus/seiza/pull/242). Remaining work includes
responsive native preparation cancellation, signed sandbox/separator QA,
source refresh, route overlays, and full draft recovery.

## Phase 4 — the whole works (long term)

- high-rate sequence review, blink/difference views, and registration
- satellite overlays with shutter-open time, observer, element epoch, and
  explicit prediction provenance
- multi-extension FITS image-HDU navigation
- lazy FITS cube slice navigation with neighboring-slice preloading
- catalog bundle update discovery and selective dataset management
- automatic updates, crash reporting, and a performance regression corpus
