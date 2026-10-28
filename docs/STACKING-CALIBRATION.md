# Graded calibration in Stack Images

Stack Images pins the shared calibration-association update in Seiza (see the
exact Git revision in `Rust/seiza-mac-core/Cargo.toml`), based on **0.46.0**,
calibration **0.10.0** and stacking **0.53.0** for library grading, per-light matching, master recipes and
shared-canvas execution. Fixed reference and Expanded mosaic both support several
calibration sessions within one output. Live acquisition retains its existing
preparation workflow.

## Use the library

1. Select lights from images, folders or TXT/CSV lists and open **Stack Images**.
2. Expand **Calibration**, choose **Graded calibration files or library**, then add
   files or choose a folder containing FITS/XISF bias, dark, dark-flat and flat frames or masters.
3. Set **Calibration matching and grading settings**, globally or for a rig.
   Per-rig controls become available after the first analysis. A rig is identified
   by the camera and telescope metadata; gain, offset and other sensor fields
   remain part of Seiza's compatibility rules.
4. Analysis runs automatically when files, lights or settings change.
   **Analyze Calibration** can refresh it manually. Discovery and measurement run off the main thread.
   This step does not build masters. Unchanged measurements are reused and
   screened again using the current settings and grading peers.
5. Open **Review Grades and Matches**. Inspect calibration grades and reasons,
   the selected files for each light, and each session's master recipes. **Keep
   out**, **Use anyway** and **Clear choice** persist against the exact source
   path and fingerprint. Choices or settings changes trigger another analysis.
6. Choose **Incomplete lights**: **Stop and review** (default), **Exclude from
   stack**, or **Keep with available calibration**. The setup checks that every
   output retains at least two usable lights when excluding incomplete ones.
7. Choose the output and stack. The app verifies the reviewed plan, builds or
   reuses masters in dependency order, and carries each light's assignment into
   planning, integration and transient-removal replay. New execution warnings,
   such as an unstable-flat retry, are shown before processing lights.

Poor raw calibration frames stay out unless explicitly allowed. Suspect frames
remain eligible and retain their reasons in review. Existing masters are adopted
under Seiza's external-master setting, rather than graded as individual raws.
Ungraded selected inputs are reported as incomplete; they are not labelled OK.
Allowing a poor/ungraded frame never bypasses sensor or optical compatibility.
Unreadable selected lights and master-build failures stop preparation with an
error; Keep/Exclude does not hide those execution failures.

## Settings and shared decisions

The app renders the shared schema's matching, dark-selection, flat-group and grade controls,
including their defaults, native units and help. It persists global settings,
per-rig overrides, quality choices, incomplete-light policy, flat star masking and
flat-stability retry options. A rig can inherit each global value independently.
Unknown keys and invalid values are rejected by Seiza before image processing.
No grading thresholds, temporal selection rules or master-selection policy are
implemented in Swift or copied into the Mac Rust adapter.

The host measures dark/bias/dark-flat and flat pixels with Seiza, then submits
immutable metadata and measurements to `seiza_calibration::library::evaluate`.
Seiza determines grading peers, grades, compatible candidates, coherent cohorts,
external-master adoption, effective gates, session identities and master recipes.
Identical recipes share cached masters across lights and output groups.

Flats and darks each have an independent **Group and match automatically** /
**Use all as one set** choice, defaulting to automatic. Automatic flats use
Seiza's raw-response preparation, bounded sample selection, pixel measurements
and requested pair comparisons to establish response groups and change windows.
The Flat groups review tab shows measured sessions, families and changes. Darks
use the existing shared sensor/exposure/temperature and temporal selection.
One-set mode includes every eligible compatible input of that kind across
nights, without the automatic 64-input cap. It retains grading/exclusions and
physical gates, refuses incompatible sets or mixed/multiple masters, and disables
alternate-flat-session retries. Stability can still trim drifting raw flats.

Response planes are cached independently of settings and pedestal estimates.
Updated settings regrade and regroup stored measurements. Pair comparison cache
keys include response source stamps, pedestal levels and metric versions.
Untimed raw flats are explicitly reported; they cannot establish temporal changes.
Unknown/inconclusive light placement is reported as incomplete calibration and
follows the selected Stop/Exclude/Keep policy.

The executor uses the native master builder with the recipe's exact dependencies,
defect suppression, masking and dark screening. Flat stability measurements feed
`library::flat_retry`: trim, alternate-session retry, retain-with-warning and
withhold decisions stay in Seiza. Retry candidates go through the complete
planner again so a different flat exposure selects its own dark-flat dependency.
For flat-only mono sessions, native pedestal fits feed the shared acceptance
policy. An accepted constant is materialized as a bias master for the fixed C
opener. Inconclusive/CFA fits withhold the flat and reapply the incomplete-light
policy; the host never silently forces a flat without pedestal removal.

## Sessions and source safety

Output groups, grading peers and calibration sessions serve different purposes.
Folders, CSV rows and sky-panel labels do not define calibration sessions. Matching
never searches for one compromise set for an entire mosaic. It preserves the
existing light/reference order and changes calibration at the assigned light.

Expanded planning calls `seiza_live_stacker_open_fits_expanding_sessions`, so each
planning reference receives the same calibration as its original light during
integration. Fixed planning opens each reference candidate under its own gate and
masters, then replaces the complete gate/rotation/master set before every push.
A failed setter aborts the push. Native history retains per-frame calibration
for A→B→A replay, including transient removal.

The Mac adapter owns recursive discovery, file identities, cached measurements,
atomic master publication and cancellation. The additional cache is under the
library's existing `CalibrationMasters` directory in `graded-library/`; live-stack
cache maintenance does not prune it. Automatic eviction for this new cache is
not implemented. Raw inputs are never modified. Declared 0:1 XISF samples are
staged in physical 16-bit ADU once, with role/calibration metadata retained.
Original paths remain visible in review and protected from output overwrite.

A review identity includes ordered sources, choices, settings and algorithm/output
versions. Changed sources or settings refuse execution until another analysis.
Device/inode/size/mtime (including nanoseconds) identify files; this is a file
stamp, not a cryptographic hash of every pixel. Staged sources and masters have
independently checked stamps, so corrupted or removed cache files are regenerated
or refused. Sources and historical masters cannot be overwritten by an output.
Scoped library/input URL access is retained during analysis, execution and the
stack, including explicitly provided file grants and after the review sheet closes. Directory symlinks are not
traversed; duplicate physical inputs are detected.

## Light evidence, corrections and manual choices

The adapter passes cached target/sensor metadata to Seiza's `plan_flat_work`.
It reads only the bounded light samples requested by the core, bins them with
the shared kernels, and submits background/response-choice and change-map fits
through `finish_flat_work`. Resolved evidence feeds the library planner before
master recipes are chosen. Change evidence excludes broad vignetting as directed
by the core; an inconclusive fit stays unknown and follows the incomplete-light
policy. Responses, light bins and evidence have separate stamped caches.

When the shared planner requires a correction, the executor loads its exact
before/after response dependencies, computes the full native change map, and
applies it to the effective flat after stability retries and pedestal handling.
Only the atomically published corrected master reaches the fixed or expanded
stacker, including transient-removal replay. A required correction that cannot
be produced aborts preparation. Corrected masters retain their acquisition and
calibration metadata and have separate cache identities.

In **Flat groups**, split an edge, join it to the previous group, or restore
measured grouping. In **Light matches**, choose a measured group or put a light
before/after an applicable change. Seiza resolves these commands and reports
applied/orphaned choices. Preferences retain them across runs; personal choices
are bound to the exact source path and fingerprint, so an identical basename
in another directory cannot inherit a choice. Changes invalidate the review.

Catalog-specific night/display controls, per-frame validity editing and light
check/report settings are not exposed in this setup. Live acquisition migration
and cache eviction/management remain follow-ups.

## Validation

[CalibrationParityTests](../Tests/CalibrationParityTests.swift) covers captured
PSF Guard screening, native session/checkpoint/replay, and the actual desktop
planner/executor/engine. The desktop tests exercise graded A→B→A assignments on
both canvases, corrected flat publication and transient-removal replay, manual
choice preference migration/round trips, per-rig gates overriding global defaults,
master reuse, Keep/Exclude/Stop preparation policy and protected/stale sources.

The [Mac Rust adapter tests](../Rust/seiza-mac-core/src/calibration_library.rs)
cover measured family/change light evidence, unknown fits, source-scoped manual
choices, split/join commands, correction pixels and cache reuse, plus poor-grade
overrides without relaxed sensor gates, native flat stability
and trimmed rebuilds, pedestal acceptance, normalized XISF staging, corrupted
cache recovery, changed settings/sources, aliases and cancellation. The
[native boundary audit](STACKING-CALIBRATION-BOUNDARY.md) records the original API
gaps and the released contracts that now support this workflow.
