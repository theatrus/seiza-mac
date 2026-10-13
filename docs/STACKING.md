# Shared stacking references

Seiza for Mac uses published `seiza-cabi` and `seiza` **0.29.1**,
`seiza-stacking` **0.31.0**, and `seiza-download` **0.8.0**. The registry
checksums are locked in `Cargo.lock`; `Shared/seiza_cabi.h` matches the
published C ABI header. These replace the tested upstream Git pin.

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
