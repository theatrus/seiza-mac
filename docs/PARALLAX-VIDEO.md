# Parallax video for Mac

Seiza for Mac **0.8.0** uses published `seiza-cabi`
**0.25.1**, `seiza` **0.25.1**, and `seiza-download` **0.8.0**, following the merge
of [seiza PR #240](https://github.com/theatrus/seiza/pull/240). The complete bridge
header matches the C ABI crate. Cargo locks the registry checksums and builds
use `--locked`; the release commit is `9f17e90f84e6841e69f8f8e39e6bd9b7e1b47c00`.

Published `seiza-parallax` **0.2.1** includes the loop and halo fixes from
[PR #242](https://github.com/theatrus/seiza/pull/242). Its renderer sources match
the previously tested patch byte-for-byte. The local vendor copy, Cargo patch
and temporary About metadata have been removed; all Seiza crates now resolve
from crates.io with registry checksums.

## Published dependency update

Seiza for Mac **0.8.1** uses published core/C ABI **0.27.0**, stacking **0.29.0**,
and parallax **0.4.0**, with the matching C ABI header and registry checksums.
The release provenance above describes the shipped 0.8.0 artifacts. Shared
stacking controls are covered in [STACKING.md](STACKING.md); the dust-map
workspace is included and tested alongside the stacking changes.

## Workspace

**File → Parallax Video…** and the viewer's film button open an independent,
resizable native window. Its full-resolution 16-bit source snapshot includes the
viewer's committed processing. Navigating or closing the viewer does not change
the video. WCS, including SIP coefficients, is reused with that exact geometry.

Source, Camera, Labels, and Output inspectors surround the preview and transport.
Tours have an ordered stop strip; selecting a stop seeks to its arrival. Stops
can be added, duplicated, removed, moved earlier/later, and picked or entered in
source coordinates. Edits and applying a generated tour support undo/redo.
Switching to Fly In retains the tour draft.

Generation returns a candidate, which can be applied or discarded. It needs
matching WCS and object catalogues, but can run before separating stars or
fetching their distances. Without WCS, the app solves first, respecting the
configured scale bounds. The composite source is tried first. If its solve fails,
an imported stars layer is retried only after the user confirms its alignment.
Preview and export use the same fallback, and the activity log records the retry
and outcome. Existing WCS is reused without solving again. Automatic separation
has no imported stars file to retry and retains upstream's original-image solve.
Generation options affect only the next candidate.

Tour JSON can be loaded and saved. It retains every stop field and the scene's
independent distance reference; the app also saves optional `tourGlide`, `tourTitles`, and `tourLoop`. Older JSON remains readable. It is
an itinerary, not a full project: it does not embed images, bookmarks, labels,
scene overrides, or export preferences.

The current workspace includes [dust maps](#dust-maps), introduced in Seiza
0.26.0 and retained in the published 0.27.0 C ABI.

## Current upstream feature coverage

| Area | Controls / contract |
| --- | --- |
| Source | Imported stretched, aligned starless and unscreened stars PNG/TIFF, or an optional installed, licensed `rc-astro` executable for StarXTerminator. The integrator name is fixed to `seiza-mac`. |
| Geometry | Source WCS, automatic solve, and minimum/maximum arcseconds per pixel. Imported layers must match dimensions and have no orientation transform; the user confirms matching stretch/alignment. |
| Distances | Separate source-point distance reference, manual background and unmatched-star parsecs, Gaia magnitude limit, opt-in online lookup, app-managed distance cache. |
| Scene | Moving-star limit, remaining stars as background field or dropped, keep galaxies in background, dust and dust opacity, and a dust map (PNG, JPEG, TIFF, FITS or XISF) that replaces the counted dust. |
| Catalogues | Existing app catalogue location; focused offline-distance download from Settings or Source; installed stellar count and magnitude coverage; optional object catalogue, object-distance and star-distance file overrides. |
| Fly In | Focus, whole-image/focus start, dolly, pan, opening zoom, end lens multiplier, start/end roll, sideways swing and direction, smooth/linear easing, duration. |
| Tour generation | Automatic or limited target count, default hold seconds, motion amount. All returned stops remain editable. |
| Tour stops | Name, independent on-screen title, focus, dolly, zoom, pan, unwrapped roll, incoming travel seconds, hold seconds, held spin degrees, and push through the remaining depth. |
| Tour motion | Overall zoom, glide through holds, fading stop titles, and seamless looping with an automatic return when needed. CW/CCW shortcuts distinguish travel turns from held spins. |
| Labels | Depth-aware catalogue labels and density; custom text, source x/y/radius and color; optional editable credit. |
| Output | 720p, 1080p, 1440p, 4K, orientation swap, custom even dimensions up to 3840 per side, 24/30/60 fps, Standard/High rendering, star growth limit and fade threshold. |
| Fit feedback | Requested versus fitted zoom, pan, lead, sideways motion, and per-stop zoom/pan. `fit.inside` drives a persistent warning below the preview and in Camera when any frames still extend beyond the image. |
| Native encoding | Silent SDR MP4 through AVFoundation/VideoToolbox, H.264 or HEVC, bounded pixel-buffer pool, hardware acceleration allowed with native software fallback. |

A stop's roll controls travel orientation; `spinDegrees` adds a turn around a held
stop and carries its accumulated angle through later stops. Positive angles are
counterclockwise. This pin starts the spin into arrival and ends it through
departure to avoid motion stopping at hold boundaries. `push` advances through a
fraction of the remaining distance during the hold, easing in and out so short
holds do not make the camera back away. Spin plus push produces a spiral. A zero
hold is a pass-through; held spin needs positive hold time. Zero incoming travel
is a cut; upstream now handles it without unbounded camera speeds.

`tourGlide = 0` restores stationary holds except at a loop join, which retains a
gentle inward zoom. The default 0.2 maintains gentle motion. Spinning stops
suppress the usual glide around their own target. The
final hold slows to rest when looping is off. Stop titles fade in and out during
held stops, independently of catalogue labels. The first stop's incoming travel is inactive. Total duration is all holds plus the
incoming travel of every stop after the first. Time values remain independent
of frame counts; the prepared summary determines the exported frame count.

Looping returns to the first view, adjusts accumulated turns for a continuous
join, and ignores the opening/closing pushes. When a return stop is needed, its
travel is the mean incoming travel and its hold is at least three seconds (or
three times the opening hold). The timeline includes that return and playback
repeats. Explicitly end at the opening focus/dolly/zoom/pan to edit its return
timing. Each stop's zoom now applies against the widest opening view; the first
stop's zoom is no longer ignored.

The `92b1604` pass incorporates upstream's camera-fit and scene/data fixes.
Whole-image moves toward an edge are fitted even without roll; a fit that still
shows an edge is explicitly reported instead of promising the framing fits.
Two-stop loops keep drifting through the join, pan and roll maintain their
speed through pass-through stops, and a closing title can span the loop join.
Tour generation now excludes targets without a distinct view before ranking
the remaining targets.

Overall/opening zoom and the star growth limit must be at least 1, matching the
new native validation; individual stop zoom remains positive. Growth measures
how much nearer a star has come: size follows its square root, so a growth limit
of 4 permits twice the original size. Stars disappear at twice the fade threshold.
The Output inspector explains both controls. Native validation also rejects
out-of-image stops and non-finite values before fitting.

The same pin improves dust near image edges, star footprints over gradients,
galaxy placement and associated labels, online Hipparcos proper-motion
matching, and Gaia cache precision. Automatically placed unmatched stars stay
off the background plane. Missing catalogue labels and unsupported glyphs now
produce warnings while keeping the prepared scene usable; Activity preserves
those warnings. Existing scene, camera, label, output and stop controls cover
this pin's request fields. Its only added C ABI summary field is `fit.inside`.
The CLI's encoder changes do not replace the Mac's native encoding path.

The `5e87c5d` update lets a lifted galaxy recenter up to 1.5 times its catalogue
ellipse's size. This recovers UGC 11678 in Iris, whose light is about 1.14 times
its size away from the listing, while retaining the rejection of a nearby
bright nebula knot. The existing **Keep galaxies on background** control still
chooses whether lifting runs. No request, summary, tour-step or header changes
were introduced by this update.

PR #242 keeps the lens drifting inward through a loop join even when the views
either side provide no natural drift. It also preserves bright-star halos with
their stars, subtracts the surrounding glow before assigning light to individual
stars, and avoids cutting unmatched halo knots into separate moving stars.
Existing loop and scene controls cover these fixes; no new request fields were
added. The native AVFoundation/VideoToolbox encoder remains unchanged.

## Dust maps

Dust dimming normally counts the dust from how few stars show through it. A
dust map replaces that count with an image painted white where the dust is
opaque and black where the sky is clear, at any size with the image's shape. In
**Source → Stars and dust**:

- **Choose Dust map…** applies a PNG, JPEG, TIFF, FITS or XISF map. What lies
  behind the nebula dims by it, and where it lets through 5% of the light or
  less (about 96% white) a star seen there flies in front of the nebula.
- **Export Dust Map…** writes the dust in use, the size of the image, as a
  16-bit PNG or TIFF or a 32-bit float FITS or XISF, to paint over. An exported
  counted map can carry small opaque specks in clear sky; paint them out, or the
  stars under them fly forward.
- **Reload** reads the chosen map again after it was edited elsewhere, and
  **Reset** returns to the counted dust.

The section says where the dust came from and how many stars the map brought in
front. The map, like the other input files, lasts while the window is open; tour
itineraries do not record it. Dust maps need dust dimming on. Export reports its
activity and prevents overlapping writes, retaining the destination's security
scope until the native write finishes.

## Scene reuse and ownership

`seiza_parallax_reconfigure_json` now implements the requested immutable scene
reuse API. The original handle and returned handle share scene data and remain
independently owned and concurrently renderable. The app sends a complete
camera/output settings object on every refit: omitted fields are upstream
defaults, not inheritance from the previous handle. Scene fields never go into
reconfiguration requests.

After **Prepare Preview**, camera, tour, label, and output edits trigger one
serialized refit worker with a 300 ms debounce. Cancellation and generation
checks discard stale results. Automatic preview can be disabled; **Update
Preview** then applies the draft explicitly. Export derives a full-resolution
handle from the cached scene. These operations avoid repeating image loading,
separation, star detection, solving, and distance queries.

Changing layers, source geometry/WCS, catalogues, distances, star placement,
dust, or galaxy placement invalidates the scene. A dust map does not: choosing,
reloading or resetting one calls `seiza_parallax_with_dust_map_json` on the
latest prepared handle, which shares the scene's planes and stars and changes
only the dust. If camera edits are still pending, the new dust is refitted to
the current draft before publication, including with automatic preview off.
The result becomes both the refit base and the preview, so later
refits and exports keep the map. The distance-reference point
is independent of camera targets, so touring another object does not silently
change the background depth.

**Download Offline Distances** installs only `star-distances.bin`,
`object-distances.bin`, and the matching `objects.bin`. It uses upstream's
`seiza-download` manifest, immutable cache, SHA-256 verification and atomic
materialization. Settings and the Source inspector share the same background
operation; it continues when a window closes. Progress shows the current file,
transferred/unpacked bytes, verification and installation. Existing database
headers are validated, with missing/corrupt files distinguished and a warning
when the selected Gaia depth exceeds the database. Installation invalidates
prepared scenes while preserving the edited tour and imported layers. Solving
catalogues remain a separate package.

The small Mac-only download/status adapter lives in
`Rust/seiza-mac-core/src/catalogs.rs`; its declarations are outside the vendored
upstream header. Direct `seiza`, `seiza-download`, and `seiza-cabi` dependencies
use the same exact Git revision in development (registry versions in released
0.8.0). The build checks their locked sources; About reports the C ABI's
version and source commit.

Catalogue label metadata is loaded lazily by upstream. Keep catalogue/file
security scopes alive with the scene and through every in-flight native call,
including after its window closes. Frames and callbacks retain their native
owners until the synchronous C operation returns. No native pointer or frame
buffer is persisted in saved JSON.

Standard preview presets use a 960-pixel long side; custom dimensions are
rounded to even preview dimensions, which can slightly change their aspect
ratio and fitting. Standard preset preview and export share the same ratio.
Playback drops frames when rendering cannot keep up; export renders every frame.
The renderer remains in Rust; Swift does not reproduce its camera or labels.

## Encoding

The writer pulls random-access frames into opaque BGRA CoreVideo buffers on a
private serial queue. It passes actual row stride and capacity to the C ABI.
A six-buffer allocation threshold and writer readiness bound in-flight frames;
frame reordering is disabled to avoid lookahead exceeding that pool. No full
movie frame array or external encoding process is used.

Timestamps are `frameIndex / fps`, beginning at zero; the session ends at
`frameCount / fps`. Color attachments use the app's sRGB transfer convention
with BT.709 primaries/matrix. Export is 8-bit SDR even with high-depth source
preparation. High quality supersamples rendering; it does not enable HDR.
Hardware encoding is permitted, not required or promised.

Output is staged in a replacement directory on the destination volume and
published only after successful finalization. Cancellation, frame errors, and
writer errors preserve any existing destination. Encoding checks cancellation
between frames and while waiting on the writer. CoreVideo allocation failures
include the status and any writer error for diagnosis.

## Code boundaries

| File | Responsibility |
| --- | --- |
| `App/ParallaxWindow.swift` | Native window, source/camera/label/output controls, preview and stop strip. |
| `App/ParallaxSession.swift` | Snapshot and file access, composition/history, planning, scene invalidation, latest-result scheduling, preview/playback and export orchestration. |
| `App/ParallaxCore.swift` | Codable scene/video/tour contracts, validation, native ownership/cancellation, events, summaries, random frames and padded BGRA. |
| `App/VideoExporter.swift` | Native encoder, timing, bounded buffers, cancellation, staging and publication. |
| `App/SeizaApp.swift`, `App/ViewerView.swift` | Menu and toolbar entry points. |
| `Shared/SeizaCore.swift`, `App/ImageExporter.swift` | Full WCS and high-depth snapshot raster support. |
| `Rust/seiza-mac-core`, `Cargo.lock`, `Shared/seiza_cabi.h` | Exact upstream dependency/header and resolved build provenance. |

Quick Look and Finder thumbnails have no video UI. All three binaries link the
same core, so the upstream Inter font's OFL notice is bundled in every target.

## Verification and remaining work

The 0.8.0 release preparation adopts published C ABI/core 0.25.1 and parallax
0.2.1. All 192 native tests, the three Rust wrapper tests, formatting, Clippy
with warnings denied, and the unsigned universal Release build pass. The C ABI
header and previously verified renderer sources are byte-for-byte matches.
The temporary renderer vendor copy and patch-only build metadata are removed.

The unsigned Debug app and both extensions build on Apple silicon; the unsigned
universal Release build also passes. The full XCTest suite passed **192 tests**,
including twenty parallax tests. Rust formatting,
Clippy with warnings denied, and wrapper tests pass.

Composite-first solving is covered by success, fallback, missing/unaligned
layers, duplicate inputs, existing-WCS reuse, dual failure and cancellation
tests. A native preparation test renders with the recovered WCS without
reopening the failed composite. A local Iris QA run forced only the composite
attempt to fail, then used the real 0.25.1 solver on `iris-sxt-stars.tif`:
it recovered centre coordinates (315.136628, 67.777619) and generated five stops.

Coverage includes tour JSON round trips, unwrapped travel turns versus held
spin/push/glide, title and loop persistence, native loop duration/closure, title
rendering after scene reuse, incoming timing, padded BGRA, random-access frames, native
H.264/HEVC encode/decode (frame count/order, timing, orientation, color), atomic
replacement and failure preservation. A reuse test removes disposable source
rasters before reconfiguration, renders old/new handles concurrently, frees the
original, and verifies cancellation leaves the remaining handle usable. Session
tests cover successive camera edits, manual preview, independent distance
reference, scene invalidation/undo, catalogue installation, and closing during
queued refits. Catalogue tests cover missing/corrupt database status, magnitude
coverage, the focused three-file selection and compressed transfer counters.

The `92b1604` regression pass additionally checks an unfit edge framing and its
successful immutable refit, matching Swift/native zoom and growth bounds,
out-of-image tour rejection, cancellation from the star-detection callback before
distance lookup followed by a successful retry, and missing catalogue/glyph
warnings without losing the prepared scene.

At `92b1604`, the offline Iris tour was regenerated and prepared in 2.17 seconds
with 5,356 distances among 139,381 detections. Its five-stop loop retained held
spin, push, pan and titles; native fitting reported `inside = true`. The native
HEVC export decoded all 338 frames at 1280 × 720 with increasing timestamps and
duration 338/30 seconds. Its midpoint was visually checked. The movie, generated
plan and logs are in `.build/qa/iris-offline-92b1604-*`. The final PR check still
matched this pin and remained open.

The `5e87c5d` pass again passed all 187 native tests, three Mac Rust tests,
formatting, Clippy with warnings denied, and the unsigned universal Release
build. Upstream's expanded galaxy regression passed for both the displaced
galaxy and the brighter neighbouring knot. The real offline Iris run explicitly
asserted the native Git pin and successful lifting of UGC 11678, prepared in
2.26 seconds, and retained the same 5,356 star distances and `inside = true`.
The fresh native HEVC movie decoded all 338 frames at 1280 × 720 with increasing
timestamps and duration 338/30 seconds; its midpoint was visually checked.
Artifacts are in `.build/qa/iris-offline-5e87c5d-*`. The final upstream check
remained open at this exact pin.

The published 0.25.0 migration with PR #242's `da4e14a` renderer patch passed
all 188 native tests, three Mac Rust tests, and all 88 renderer tests, plus
formatting, Clippy with warnings denied, and the unsigned universal Release
build. The new native regression checks continued motion and smooth wrapping
when identical stops provide no natural drift, including zero glide. The
published C ABI header matches byte-for-byte; the patched renderer files match
the recorded upstream fix exactly. Offline Iris prepared in 2.98 seconds with
5,356 star distances, successful lifting of UGC 11678, and `inside = true`.
The five-stop tour retained spin, push, pan and titles. All 338 native HEVC
frames decoded at 1280 × 720 with increasing timestamps and duration 338/30
seconds; the midpoint was visually checked. Artifacts are in
`.build/qa/iris-published-da4e14a-*`.

One earlier full-suite run had a transient HEVC buffer-allocation failure. The
subsequent focused and full suites passed. Retain diagnostics and investigate if
this recurs in longer or representative exports.

Live UI testing opened a 9595 × 6346, 16-bit Iris TIFF with its matching imported
starless/stars layers, installed the standard mirror catalogues through Settings,
prepared 139,381 detected stars, changed camera settings using scene reuse, and
exported a 1280 × 720 H.264 movie through the native save panel. All 60 frames of
the two-second movie decoded with the expected timestamps; orientation and color
were visually checked. The source had no offline star distances and correctly
reported its fallback. Object distances were installed from the mirror with
SHA-256 verification. The segmented picker labels were hidden to avoid vertical
wrapping.

The offline download controls were checked in both Settings and the Source
inspector, including the unavailable-publication error before the upload
finished. After publication, the native Settings download fetched 748.5 MB of
compressed stellar data and installed the three-file selection. The database
contains 78,070,353 stars through Gaia magnitude 16; the installed 1,015,054,688
bytes match mirror SHA-256
`9b177d82044d631e12912593bc7faa70097933de0fe41de07f119a57d9c23d30`.
Using the supplied Iris WCS and online lookup disabled, the same Swift core
prepared in 2.28 seconds, read 11,928 Gaia and 21 Hipparcos stars from the local
file, and assigned distances to 5,356 of 139,381 detected stars. The generated
five-stop loop with titles, pan, spin and push exported via native HEVC.
All 338 frames decoded at 1280 × 720, 30 fps, with strictly increasing
timestamps and duration 338/30 seconds. A live app run using its own plate solve
and online lookup off assigned distances to 5,886 stars. Verify/Update reused
the installed cache, invalidated the existing preview, preserved the imported
layers, and allowed successful preparation again. The final focused native
suite passed all 16 catalogue/parallax tests after the full 183-test suite.

Online Iris QA fetched 10,574 Gaia sources and matched 5,384 detected stars,
5,339 with usable distances. A generated two-target itinerary selected the Iris
nebula at about 355 pc; unmatched stars used 1,134 pc. A five-stop loop with
editable titles, spin, push, and pan exported through the app's Swift core and
native HEVC encoder at 1280 × 720, 30 fps. All 338 frames decoded, with duration
338/30 seconds and strictly increasing timestamps. The UI also generated and
applied a five-stop Iris itinerary. A subsequent live app run plate-solved the
source itself, found distances for 5,885 stars, loaded the edited tour JSON, and
verified titles and preview playback wrapping across the loop. The 5,339-match
export above used the supplied Iris WCS sidecar instead. These runs use imported
layers, not the licensed automatic separator.

Online preparation shows elapsed time, fresh Gaia regions received, a separate
Hipparcos lookup stage, and a delayed-service explanation after 15 seconds with
no catalogue update. Its timestamped Activity popover stays available during
preparation and preserves warnings. Counts describe newly downloaded regions,
not an overall percentage, because completed regions may already be cached.
Cancellation remains pending until the current native step returns. The current
ABI only supplies textual notes for these phases; unknown notes remain readable.
Structured stage/region/cache/retry events and cancellable archive requests
would allow more exact progress without parsing notes.

Release builds explicitly keep Rust dependencies unstripped because the macOS 27
loader rejected stripped host proc-macro dylibs with a misaligned LINKEDIT string
pool. Xcode still controls stripping the final app. Both Rust architecture targets
are required for the universal build.

Release QA still needs the real licensed StarXTerminator executable from a
signed sandboxed app, signed-sandbox bookmark behavior, Intel runtime/software encoding,
unsupported codecs, larger-image memory characterization, wider astronomical footage,
faint gradients, saturated stars, galaxies, and moving labels. The optional
separator UI does not establish its signed distribution feasibility.

Upstream preparation checks cancellation between stages, during camera fitting
and while planning labels. The Swift bridge maps a stopped preparation to
`CancellationError` after releasing the native error string. Cancellation still
has coarse sections: solving, distance requests, and standalone tour planning
can delay completion. The app waits safely for native calls and discards
cancelled results, but cannot interrupt every stage.
Structured stage/error/provenance data and documented pixel/color/timing
contracts would improve release behavior. No new camera-reconfiguration API is
needed for the current controls.

Further product work includes full draft recovery/source bookmarks, explicit
source refresh, numbered route overlays/drag reordering, richer catalogue target
selection, and recombination inspection of imported layers. HDR, 10-bit, ProRes,
and audio are outside this initial export path.

PRs #240 and #242 are merged and their changes ship in the published crates.
For future updates, review the release and update dependencies, lockfile and header
together. Map any new scene/video/stop fields to the inspectors and rerun the
native and Rust checks, including renderer regressions and representative exports.
