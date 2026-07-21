# Roadmap

## Phase 1 — native viewer foundation

- FITS/JPEG/PNG/TIFF document registration, mixed-format directories, and
  multi-window opening
- fast mono, RGB, and OSC/Bayer autostretch
- header/statistics inspector
- blind solve action with security-scoped catalog selection
- Quick Look preview extension
- signed, notarized Apple-silicon development distribution

## Phase 2 — serious inspection

- fit-to-window, pan, pixel loupe, histogram, black/midtone controls
- linked and unlinked RGB stretch modes
- star-detection overlays and measured HFR/FWHM
- solved sky grid, compass, scale bar, and WCS cursor readout
- hinted solving from FITS headers before blind-solving fallback
- cancellation and in-process catalog/index caching
- sidecar export with typed provenance and FITS WCS card export

## Phase 3 — system integration

- `QLThumbnailProvider` Finder thumbnails and file-icon badging
- Spotlight metadata importer for selected FITS headers
- “Open Rendered Image in Preview” TIFF handoff
- Finder Quick Actions for solve and export

## Phase 4 — the whole works

- sequence browsing and rapid next/previous frame comparison
- blink/difference views and registration
- coordinate-only deep-sky, star-name, minor-body, transient, and satellite
  overlays with explicit source/epoch provenance
- multi-extension FITS and cube navigation
- managed catalog download/update UI using Seiza's verified bundles
- universal signed releases, updater, crash reporting, and performance corpus
