# Shared stacking references

This branch targets `seiza-cabi`/`seiza` **0.48.0**, `seiza-stacking` **0.55.0**
and calibration **0.11.0**. Cargo pins the shared file coordinator
commit from [Seiza #406](https://github.com/theatrus/seiza/pull/406) and `Shared/seiza_cabi.h` matches its generated header. The graded setup
calls the shared C ABI directly; the native library/session/evidence orchestration
lives in Seiza. Its fixed and expanded
executors and replay tests are enabled. See the
[calibration setup guide](STACKING-CALIBRATION.md) for supported inputs and limits.

## Upstream coverage

| Upstream change | Mac integration |
| --- | --- |
| [#245: shared alignment image](https://github.com/theatrus/seiza/pull/245) | Optional FITS/XISF alignment image in directory and live stacking; one common canvas across filters, separate per-channel normalization |
| [#246: shared-reference C ABI](https://github.com/theatrus/seiza/pull/246) | Empty native accumulator initialization, explicit first-light push, separate reference metadata, checkpoint identity and output protection |
| [#247: ranked fallback](https://github.com/theatrus/seiza/pull/247) | Automatic scoring passes up to five ranked compatible lights to the native candidate API; selected light and skipped-candidate reasons are shown |
| [#248: Python reference selection](https://github.com/theatrus/seiza/pull/248) | Python wrapper change; no additional Mac control required |

## Using the controls

In **Stack Images**, select the lights and optionally split them by filename
filter. Each group has a channel-reference picker and automatic-selection
toggle. Automatic selection scores the current inputs when stacking starts,
so changing the selected lights cannot leave a stale ranking.

Choose **Shared alignment image** to give all groups the same bounds and
coordinates. The image can be a previously integrated channel stack. It supplies
geometry, not the channel's brightness or noise scale. Its pixels are not
integrated unless it is also explicitly included among the selected lights.
Without this option, the channel reference supplies both roles as before.

**Live Stack** offers the same alignment-image picker and automatic channel
reference selection. The watched folder excludes the alignment image. Stable,
raw lights are filtered for compatible camera geometry and filter before
ranking. An empty capture folder waits for its first stable light. The status
card shows the alignment image and actual channel reference; fallback reasons
appear in the attention list. Saved sessions retain both reference roles. With
Resume enabled, an empty alignment picker restores the saved alignment image.
To start a new stack without a shared grid, clear the picker and disable Resume.

The shared image must have compatible mono/color channels and approximately
the same pixel scale. Different binning or a mono image paired with color
lights is not supported. Automatic fallback only handles alignment failures;
read, calibration, and channel-count failures stop the operation. A manually
chosen channel reference is never silently replaced.

## Driver and lifetime guarantees

- Legacy open integrates its reference immediately. Shared-reference open
  starts at zero; both Mac drivers push the selected channel light first, then
  process the remaining lights. The alignment image never inflates counts.
- Failed reference candidates remain lights to process normally. Reference
  selection failures do not themselves inflate rejected-frame counts.
- Native candidate selection is synchronous and prepares the alignment image
  once. Cancellation is checked around the call, and ownership is retained
  until it returns. Live candidate stability is checked before and after
  opening/integrating the first light. A cancelled initialization closes its
  private accumulator without publishing a partial ledger.
- Checkpoints record `referenceImagePath` and `referenceIntegrated`. Older
  checkpoints without the fields remain readable. A different configured
  alignment image cannot be restored as the same stack.
- Batch output preflight protects every group's lights, masters, and alignment
  image before writing any output. Export, reintegrated, and finished snapshots
  retain protected paths, including after their native session closes. Final
  destinations are checked before atomic staging, including symlinks and hard
  links to protected inputs.

## Validation

Native contract tests exercise ranked-reference validation, quarter-turn
alignment fallback, terminal read errors, empty shared-grid initialization,
explicit reference integration, checkpoint round trips, source protection for
snapshot/reintegration/final export, batch cross-group protection, and live
selection/resume. Existing stack recipes and parallax tests run against the
same pinned core. See the pull request for the completed check results.

## Flat quality review

The proposed [calibration workspace in stacking setup](STACKING-CALIBRATION.md)
extends this foundation to PSF Guard-style frame grades, measured flat groups,
per-light matching and multiple calibration sessions on one fixed or expanded
canvas. That feature is planned; the current output-level calibration remains
the behavior described in the existing guides.

Both directory and live stacking offer **Review flat quality** when building
masters from calibration frames. It measures the selected raw flats and shows
native frame/master verdicts before any light is processed. See
[Calibration quality](CALIBRATION-QUALITY.md) for saturation units, optical
geometry, the review's limits and the API coverage audit.

## Median Anchor and Layered display stretches

The image stretch panel includes Median Anchor and Layered under Automatic.
Median Anchor exposes target median, optional robust black-point clipping (or
the image minimum), quarter-tone curves boost, highlight compression/knee and
normalization. Layered exposes target background, aggressiveness, star-core
compression, large/detail scale separation, contrast recovery, saturation lift
and protection for dark noise. Every parameter survives recipe/clipboard JSON,
ordered stages, undo/redo and full-resolution 16-bit export.

Layered defaults to linked colour handling so it works with mono and RGB data.
Per-channel mode is rejected; RGB users can also select Preserve Luminance Color.
Live Stack offers Auto MTF, Median Anchor and Layered before and during a run.
Changing that choice only redraws the preview: physical sample-domain mapping,
linear accumulation, checkpoints and saved FITS pixels remain unchanged.

## Independent live stacks by filter

Enable **Separate stacks by filter** in Live Stack, and **Include subfolders**
when capture files are nested. Metadata filter names take precedence over filename
fallbacks; absent filter information goes to **Unfiltered**. Each discovered
filter owns its accumulator, reference light, preview, admission ledger,
calibration history and checkpoint. **All Filters** shows live preview cards for
every unfinished filter together, including per-filter state, accepted/rejected/
skipped counts and attention messages. Cards resize with the window and group
count; larger sessions can scroll. Click a card to switch to **Selected Filter**
for the full preview, depth chart, snapshots and finishing. The Filter picker
retains access to every group, including completed stacks. Existing single-stack behavior and checkpoints remain the
default when the option is off.

Automatic calibration is matched independently to each filter's first light;
quality reviews are presented sequentially. Manual masters apply to every group
and must be compatible. An optional shared alignment image gives all filters a
common canvas without mixing their brightness/noise normalization. At most two
group startup/ingestion operations run concurrently. A failing filter does not
stop the other groups.

**Pause and Save All** stops discovery and checkpoints every unfinished group.
**Resume All Filters** restarts them. Snapshot and Finish affect the selected
filter; finishing opens its output and leaves the other filters running.
Completed groups retain their output location and do not restart when more files
of that filter arrive. A saved session restores completed and unfiltered groups
even when the original capture files are no longer present. One window owns a
capture session at a time.

Save outputs outside both the capture tree and session checkpoint tree. The
preflight also rejects hard-link/symlink aliases to any group's protected inputs
or checkpoint metadata. A completion record is saved before retiring the native
checkpoint; a failed completion write retains the checkpoint for recovery.

Native regressions cover recursive discovery, filter isolation, late groups
inheriting the chosen display stretch, independent finish, continued ingestion,
source-less resume, exclusive ownership, per-filter calibration failure/cancellation and
cross-group output protection. Cancelling a calibration review pauses only that
filter and does not retry the review or count the light as unreadable. Pause/close
suppresses pending and queued calibration reviews before waiting for workers;
calibration failures never enter the automatic-reference fallback path. The UI was exercised with H-alpha, OIII and
Unfiltered lights, including finish, pause and resume.

## Mosaic panels and GPU settings

See [Mosaic stacking and GPU performance](MOSAIC-STACKING.md) for automatic
coordinate-based panel/exposure selection, expanded canvases, memory limits and
the persistent Settings GPU preference. Live acquisition retains its fixed
canvas; resumed accumulators retain their saved GPU policy.
