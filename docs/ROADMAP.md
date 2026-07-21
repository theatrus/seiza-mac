# Roadmap

## Phase 1 — native viewer foundation

- FITS/JPEG/PNG/TIFF document registration, mixed-format directories, and
  multi-window opening
- fast mono autostretch plus per-channel Auto, Linked Auto, and Linear RGB
  display modes for planar-RGB and OSC/Bayer images
- header/statistics inspector
- blind solve action with security-scoped catalog selection
- catalog-colored, independently toggleable solve overlays for named stars,
  deep-sky catalogs and OpenNGC contours, transients, acquisition-time comets
  and asteroids, field stars, coordinate grid, labels, and field center
- HIG-style FITS document icon and Quick Look preview extension
- signed, notarized Apple-silicon development distribution

## Phase 2 — serious inspection

- fit-to-window, pan, pixel loupe, histogram, black/midtone controls
- star-detection overlays and measured HFR/FWHM
- compass, scale bar, and WCS cursor readout
- hinted solving from FITS headers before blind-solving fallback
- cancellation and in-process catalog/index caching
- sidecar export with typed provenance and FITS WCS card export

## Phase 3 — system integration

- `QLThumbnailProvider` Finder thumbnails
- Spotlight metadata importer for selected FITS headers
- “Open Rendered Image in Preview” TIFF handoff
- Finder Quick Actions for solve and export

## Phase 4 — the whole works

- sequence browsing and rapid next/previous frame comparison
- blink/difference views and registration
- satellite overlays with shutter-open time, observer, element epoch, and
  explicit prediction provenance
- multi-extension FITS and cube navigation
- managed catalog download/update UI using Seiza's verified bundles
- universal signed releases, updater, crash reporting, and performance corpus
