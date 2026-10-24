# Mosaic stacking and GPU performance

The Mac workflow ports [seiza-win PR #70](https://github.com/theatrus/seiza-win/pull/70)
using published Seiza/C ABI 0.42.0 and stacking 0.45.0. It does not change the app
version or publish a release.

## Select panels by sky coordinates

1. Open a directory and choose **Stack**.
2. Turn on **Group mosaic panels by solved coordinates**. Select 2–512 lights
   and click **Solve and group selected lights**. Install the standard solving
   catalogs in Settings first.
3. Under **Select panels to include**, select whole panels or expand them to
   select individual exposures. The first sky field is selected initially;
   other fields are available but unchecked. Calibration frames, masters,
   failed solves and unconfirmed coordinates appear under **Excluded**.
4. Review the selected-light/output summary, filter splitting, calibration and
   stack options, then choose **Choose Output and Stack…**. Every output needs
   at least two lights. Multiple outputs use a folder and base name with unique
   field/region/filter suffixes.

**All** selects only successfully analyzed lights once an analysis exists.
To analyze previously excluded or unselected files, turn automatic grouping off,
select the files, turn it back on and solve again. A cancelled analysis keeps
its prior result and selection. Cancellation waits for the current solve to
return; footprint comparison checks cancellation between batches.

The app compares footprints through the published native TAN/SIP transforms,
including rotation, RA wrap and polar fields. At least 85% mutual footprint
coverage groups repeated pointings into a panel; at least 5% connects panels
into a sky field. Complete-link repeat clustering prevents a chain of dithers
from swallowing a whole mosaic. Removing a bridge splits disconnected outputs.
Connectivity is recomputed separately for each selected filter, so another
filter cannot supply a bridge for that output. Field labels stay stable when
other fields are deselected.

This grouping selects inputs. Native star registration still determines which
lights can be integrated. Sources are checked for size, modification time and
file identity before using solved selections; solve again if a source changes.
Outputs cannot replace any original input, including unselected or excluded
files, calibration masters or a shared alignment image.

## Choose canvas and memory

**Fixed reference** retains the reference grid. An optional shared alignment
image puts filter stacks onto one common fixed grid while each channel retains
its own brightness scale.

**Expanded mosaic** plans bounds from the full selected light list and retains
panel edges. The first ordered light anchors geometry and brightness; automatic
reference selection can choose the anchor. The planner starts empty, so every
light, including the anchor, is integrated exactly once. Results report canvas
size, native planning notes and any measured lens correction.

The canvas limit is in millions of samples: pixels times channels. Native peak
working memory is approximately 40 bytes per sample, so the default 256 million
samples can require about 10 GB. Lower the ceiling on smaller-memory Macs.
Exceeding it fails planning before output is written.

The initial minimum overlap is 60% for fixed grids and 5% for expanded canvases.
Editing the overlap explicitly preserves that value across canvas switches.
Expanded canvases cannot use Bayer drizzle or a shared fixed alignment image.
Live acquisition uses a fixed canvas. Separately stacked filter mosaics do not
promise a shared RGB grid. No new binned or drizzle reintegration controls are
introduced.

## Use GPU for stacking

**Seiza → Settings → Stacking performance → Use GPU for stacking** persists
across application restarts and defaults to on. Automatic mode uses available
native GPU operations, with CPU fallback for small frames and unsupported
operations. Turning it off sends `gpu.enabled=false` for new directory and live
stacks, including native cosmetic processing and final reintegration. GPU and
CPU results can differ slightly; automatic mode does not promise a speedup for
every image or device.

Each run captures its policy when it starts. Changing Settings does not alter an
active accumulator. A compatible resumed live stack retains its original saved
policy and options JSON and shows a notice when that policy differs from
Settings. GPU policy alone does not invalidate a checkpoint; other processing
options still must match. A checkpoint does not require its original reference
file merely to restore the accumulator.

## Port validation

Local validation after review and rebasing onto current main on 2026-10-23
passed 287 Mac tests (5 optional local-fixture skips), 5 Rust tests, Rustfmt,
Clippy with warnings denied, the universal arm64/x86_64 Release build and
unsigned-app validation. The bundled header matches the published 0.42.0
header, including the 80-byte SNR structure.

Before rebasing, the running native Mac app solved six catalog-based synthetic exposures into
two overlapping panels plus a separate sky field. Panel checkboxes and
individual exposure selection updated the selected-light/output summary. The
selected four-exposure mosaic exported at **1211 × 609**, with **4 accepted / 0
rejected**, and SHA-256 checks confirmed all six source files were unchanged.
These were procedural catalog-star fixtures, not telescope exposures or a GPU
speed benchmark. Both CPU-only and automatic policies also passed native
expanded-stack/reintegration tests; this validation does not claim device
compute for the small fixtures. Live checkpoint tests covered preference
changes in both directions and restoration after removing the source reference,
including multi-filter sessions and filters discovered later. Review also added
regressions for changed/retargeted symlinks and excluded-input hard-link output
protection.
