# Native calibration boundary

Audit baseline: Mac `d063c9b`, C ABI 0.44.2, calibration 0.8.1, stacking 0.51.2;
PSF Guard `79f5e31d53b8371e8fcd0b22a9b69692412cd8b4`.

At that audit baseline, the core could integrate different calibration sessions
on a shared canvas and replay those assignments, but lacked the shared PSF Guard
planning policy and expanded raw-file planning under per-light calibration.

The current setup uses the file coordinator from
[Seiza #406](https://github.com/theatrus/seiza/pull/406), based on core/C ABI
0.47.0. Swift calls `seiza_calibration_files_json` directly. The upstream Rust
coordinator holds `RuleBook`, `QualityIndex` and `Library`, drives native evidence,
master generation, retries and corrections, and returns prepared file sessions.
The app-owned Rust coordinator and its custom C export are removed. Swift keeps
scoped access, preferences and review. Database clients retain the native stages
introduced by #403 and can use their own catalog/caches/pixels.

Both canvas modes use per-light sessions during planning, integration and replay.
Desktop tests cover A→B→A calibration, per-rig gates, and required corrected
flats. File-level fixtures cover measured responses, family/change light
evidence, unknown fits, manual group/side choices, source isolation, master
reuse and set-based session identity. This covers the setup's supported inputs;
full PSF Guard UI/catalog parity is not claimed. See the
[current setup and limitations](STACKING-CALIBRATION.md).

## Verified contracts from the original audit

| Capability | Audited boundary | Evidence and limitation |
| --- | --- | --- |
| Bias/dark measurement | `seiza_calibration_measure_dark_json` | Typed Swift wrapper retains every native field, physical sample units and algorithm version; stored measurements can be screened after the file is removed |
| Bias/dark/flat grades | `screen_bias_json`, `screen_darks_json`, `screen_flats_json` | Captured PSF Guard measurements give matching native grades/main finding codes; this does not choose peers or apply library overrides |
| Sensor/optical matching and common cohorts | Existing signature matchers and `seiza_calibration_plan_json` | Useful primitives; do not reproduce PSF Guard's temporal, validity, response-family or recipe selection policy |
| Master generation | `seiza_calibration_build_master_json` and existing Mac preparation/cache | Available; the current Mac preparation request still chooses one safe set for all its targets |
| Master replacement | `seiza_live_stacker_set_calibration_fits` | Path-based A→B→A replacement preserves recipes and deduplicates master paths in the native ledger; differing gains work when each pushed light matches its own set |
| Effective gate | `set_match_tolerances`, then `set_light_rotation` | Recorded 40° light/90° flat is refused under the recorded basis and admitted under measured 90°; another session restores the recorded basis |
| Checkpoint/replay | `save_context`, `open_context`, `reintegrate` | Fixed and truly expanded footprints retain per-frame masters/gates; replay agrees per pixel within 0.01 ADU; a missing historical B master fails even after A becomes active again |
| Prepared file open | `seiza_live_stacker_open_prepared_fits` | Creates prepared-only array-input mode and refuses master/gate replacement; it is not a raw-file multi-session planner |

Master replacement validates master geometry/layout before committing. Actual
acquisition and optical compatibility is checked against each pushed light.
The generated C header's phrase “validated against the immutable registration
reference” must not be interpreted as requiring every later session to share
the reference's gain/rotation. The boundary test intentionally uses both
different gain and a different flat angle. Geometry remains common to a stack.

All native operations require exclusive access to the handle. Gate and master
setters are separate calls, not one transaction. The executor must validate
a session before applying it and abort the pending push if any setter fails.
Never continue with a previous session after a failed switch. Set tolerances
before the light-rotation basis: resetting tolerances restores recorded angles.

## Shared policy and remaining host work

The captured [reference fixtures](../Tests/Fixtures/CalibrationParity/README.md)
include actual PSF Guard selections, eligibility/override transitions, master
counts and gates, and measured response-family/group/event decisions. Mac tests
compare captured screening records and exercise the native planner/executor on
file fixtures; they do not compare every catalog-level PSF Guard decision.

The reusable policy behind PSF Guard's library selection and measured flat
groups is now in Seiza, with versioned records and explanations through C and
Python. Keep database, filesystem/cache and bookmark access in the hosts.
Complete measured-family fixture comparisons remain a prerequisite for claiming
full parity. The enabled shared path preserves ungraded eligibility, suspect warnings, poor exclusion, persistent
choices, hard compatibility, measured/unknown angle bases and fitted pedestal
recipes. Default numbers must come from the shared implementation.

This first fixture set is not exhaustive. Add moved dust and response extraction
from actual images, inconclusive light fits, manual family choices, dark age/
reach/cohort boundaries, readout-mode names, validity boundaries, mixed filters,
missing metadata and physical/normalized XISF before claiming full parity.

## Expanded planning audit and released API

`seiza_live_stacker_open_fits_expanding` accepts one bias/dark/flat set and one
dark exposure override. In stacking 0.51.2, `expand::plan` prepares **every**
planning input with that one set before measuring its stars and footprint.
Changing masters after opening only changes integration. It cannot repair the
already prepared registration references.

The boundary test deliberately plans raw panels without masters to isolate the
available integration/replay contract. That is not the production solution.
PSF Guard instead prepares correctly calibrated scratch reference images before
planning, then integrates original raw lights with their assigned sessions.
That Rust path is not equivalent to the prepared-only C open.

The published session-aware core operation and C/Python bindings now provide
the required file-planning contract:

1. Accept original light paths in caller order, each light's session assignment,
   exact master paths/dark exposure, effective tolerances and rotation basis.
2. Validate assignments and source identities, and calibrate each planning
   reference under its assigned recipe before star detection/demosaicing.
3. Return an empty, file-input stack with the expanded grid and planning notes;
   preserve original identities and recipe provenance, not only scratch paths.
4. Integrate original lights with those same assignments. Count an anchor once,
   retain per-light gates/recipes for replay and protect all source/master files.
5. Account for all active master/reference memory and scratch leases, with
   cancellation and sample ceilings throughout preparation and planning.

The request shape should be shared with the eventual executor rather than
adding another unrelated session format. Prove C/Python binding parity, fixed
and expanded outputs, replay, CPU/GPU fallback and cancellation before enabling
additional measured-family behavior. The current desktop executor has fixed and
expanded output/replay and per-rig gate coverage. Follow the Seiza processing-output version procedure for
any changed processing behavior. The Mac orchestration uses the published processing
algorithms and output versions unchanged.

Continue with the [stacking setup plan](STACKING-CALIBRATION.md).
