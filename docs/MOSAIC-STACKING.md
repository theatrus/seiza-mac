# Mosaic stacking and GPU performance

The Mac workflow ports [seiza-win PR #70](https://github.com/theatrus/seiza-win/pull/70)
and PR #73 using published Seiza/C ABI 0.44.2 and stacking 0.51.2. It does not change the app
version or publish a release.

## Stack selected lights on an expanding canvas

1. Open images, a directory, or a TXT/CSV image list and choose **Stack Images**.
2. At the top of the dialog, choose **Stacking mode → Expanded mosaic**.
3. Select the lights to include, review filter splitting, calibration, and the
   canvas memory ceiling, then choose **Choose Output and Stack…**.

Each output registers its selected lights onto one expanding canvas. Inputs can
come from different folders; overlapping panels can connect through other panels.
No sky-panel analysis or pre-solving catalogs are required for this workflow.
Native star registration decides which lights join, and disconnected images may
be rejected. Optional filter splitting creates a separate canvas for each filter.
There is no 512-light selection cap; canvas size and available resources still
bound what can be processed.

## Optional sky-panel analysis

This is a selection aid for reviewing pointings and separating disconnected sky
fields before stacking. It is independent of the chosen stacking mode.

1. Expand **Optional sky-panel analysis** and turn on **Group lights by solved
   sky position**.
2. Select at least two lights and click **Solve and group selected lights**.
   Install the standard solving catalogs in Settings first.
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
Larger selections use smaller row batches to keep cancellation responsive.
The full footprint matrix and pair comparisons grow quadratically with the number
of successfully solved lights, so large selections need more time and memory.

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

Automatic calibration can grade a library, match each light independently, and
build/reuse its native master recipes. One mosaic output can use several
calibration sessions. Expanded canvas planning and integration receive the same
per-light assignments, including when lights alternate between sessions. See
[graded calibration setup](STACKING-CALIBRATION.md) for review and global/per-rig
settings. Flat-family evidence is currently limited to Seiza's metadata/time
fallback; measured dust/response families are not supplied by this setup yet.

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
Expanded canvases cannot use local normalization, Bayer drizzle or a shared fixed alignment image.
Choose local-background, global, or no normalization for expanded mosaics.
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
active accumulator. A compatible resumed live stack applies the current GPU mode
and planning budget through the native resume API, retaining frame history,
registration and rejection state. The next checkpoint records the updated
policy. GPU policy alone does not invalidate a checkpoint; other processing
options still must match. A checkpoint does not require its original reference
file merely to restore the accumulator.

The **GPU planning budget (MiB)** is persistent. `0` selects automatic planning;
positive values through 1048576 are a soft device-memory planning budget. This
can keep work on the CPU when GPU memory is insufficient; it is not a process
memory limit. Every filter, including filters discovered later, inherits its
run's captured mode and budget.

The Mac viewer renders through CPU-backed CGImages, so the Windows-specific
Win2D virtual-bitmap implementation is unnecessary. Full-resolution 8/16-bit
renders wider than 20000 pixels are covered by integration tests, and the
viewer can fit images at zoom levels below 1%.

## Port validation

The original PR #70 port was validated with catalog-star procedural mosaics
(1211 × 609, four accepted frames, source hashes unchanged). Current automated
coverage also exercises published expanded planning, sample ceilings,
checkpoint resume with changed GPU mode and budget, and multi-filter resume
after removing the source images. Small procedural fixtures do not demonstrate
device GPU execution or performance.
