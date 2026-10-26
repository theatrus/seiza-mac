# Color Tools

Open **File → Color Tools…**. This Mac workspace ports the workflows in
[seiza-win PR #73](https://github.com/theatrus/seiza-win/pull/73) using published
Seiza/C ABI 0.44.2 and stacking 0.51.2. The app version is unchanged.

Choose aligned, prepared mono or RGB FITS/XISF images. Raw Bayer inputs are
rejected. Confirm a common aligned pixel grid: matching dimensions alone do
not prove alignment. Linear inputs must retain their original common physical
photometric scale. Background-subtracted, independently normalized images can
violate that condition.

Required inputs and common choices appear first. Optional processing and fit
settings start collapsed. A wide window shows the preview beside a scrolling
inspector; a compact window puts it below the controls. Build and save actions
remain at the bottom.

## Workflows

- **Narrowband palette:** choose Hα/O III for HOO, or Hα/O III/S II for SHO.
  Declare linear or already display-referred inputs. Linear inputs receive a
  linked physical-domain stretch. Optional balancing exposes shadow protection,
  O III/S II boosts and detected-star exclusion. A display RGB structure image
  can supply broadband structure. Green reduction follows nebula preparation.
- **Continuum subtraction:** choose a line image and one to three continuum
  references on the same linear scale. Automatic analysis needs a producer
  saturation ceiling or producer mono 0/1 clipping mask for every source;
  `0` means unknown. Never substitute the observed image maximum. Optional
  Gaussian PSF matching precedes fitting. **Analyze stars** produces no image.
  Review coefficients, validation-star count and fractional RMS before building
  a subtraction preview. A skipped fit remains skipped. Manual nonnegative
  coefficients require explicitly choosing manual mode. Residuals retain signed
  linear float values, negative samples and missing-coverage NaNs.
- **Extract and stretch RGB stars:** subtract a starless linear RGB image from
  its original RGB image on the same scale; choose star stretch amount 0–8.
- **Restore RGB stars:** extract/stretch stars from an original/starless linear
  RGB pair, prepare a linear or display nebula, reduce nebula green, then screen
  the stars with linked star reduction.
- **Restore prepared display stars:** screen an already display-referred RGB
  star layer over a linear or display nebula. The stars receive no second stretch.

## Preview, save and reopen

Processing writes a private temporary float preview. **Save built image…**
converts that cached result to FITS or XISF; it does not reprocess the original
sources. Changing inputs/settings invalidates previews and stale fits. Closing
or cancelling waits for an in-flight native operation and discards its result.

Native orchestration checks exact SHA-256 source bytes before and after work.
Saving protects source images, clipping masks, structure images, loaded plans
and the built preview, including symbolic/hard-link aliases. Publication stages
completed data on the destination volume and atomically replaces the chosen
file only after successful processing and a cancellation check.

Results record `SEIZATRF=DISPLAY` or `LINEAR` and `SEIZA*` provenance. Format-only
FITS/XISF saves retain these cards. Display products start with **No Stretch**
and an explicit numeric 0–1 sample domain in the viewer, thumbnails, Quick Look
and 8/16-bit renders. Explicit later stretch edits remain available. Linear
scientific products retain the normal initial viewer stretch.

## Continuum plans

**Save report / plan…** writes JSON containing source paths and hashes,
producer saturation/clipping metadata, coefficients, PSF preparation and
validation diagnostics. **Load continuum plan / report…** restores paths and
producer metadata from a full report and resets alignment/linear confirmations.
A bare plan retains the currently selected paths. Building revalidates exact
source hashes and grid against the native plan. Changes to source bytes or
producer metadata require a new plan. No path-only match is accepted.

## Folder aliases and large images

The corresponding change from
[seiza-win PR #74](https://github.com/theatrus/seiza-win/pull/74) resolves macOS
Finder image aliases during directory scanning. Image targets are deduplicated;
folder aliases are not traversed. Unresolvable aliases appear as scan issues.
The existing CPU-backed image pipeline supports wide mosaics without the
Windows-specific Win2D bitmap-limit workaround.
