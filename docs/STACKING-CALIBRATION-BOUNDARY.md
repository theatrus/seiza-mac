# Native calibration boundary

Audit baseline: Mac `d063c9b`, C ABI 0.44.2, calibration 0.8.1, stacking 0.51.2;
PSF Guard `79f5e31d53b8371e8fcd0b22a9b69692412cd8b4`.

The current core can integrate different calibration sessions on a shared
canvas and replay those assignments. It cannot yet expose the complete PSF
Guard planning policy or plan an expanded raw-file canvas with different
calibration for each planning input. Keep the setup feature disabled until both
gaps are closed.

## Verified contracts

| Capability | Current boundary | Evidence and limitation |
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
setters are separate calls, not one transaction. A future executor must validate
a session before applying it and abort the pending push if any setter fails.
Never continue with a previous session after a failed switch. Set tolerances
before the light-rotation basis: resetting tolerances restores recorded angles.

## Shared policy still needed

The captured [reference fixtures](../Tests/Fixtures/CalibrationParity/README.md)
include actual PSF Guard selections, eligibility/override transitions, master
counts and gates, and measured response-family/group/event decisions. Mac tests
currently compare **screening**, not the complete planner's decisions.

Extract the reusable policy behind PSF Guard's library selection and
`flat_groups/measure/{model,lights,overrides,rows}` into Seiza. Keep database,
filesystem/cache and bookmark access in the hosts. Expose versioned records and
explanations through both C and Python. Run these fixtures against that shared
implementation before replacing PSF Guard's policy or enabling Mac controls.
Preserve ungraded eligibility, suspect warnings, poor exclusion, persistent
choices, hard compatibility, measured/unknown angle bases and fitted pedestal
recipes. Default numbers must come from the shared implementation.

This first fixture set is not exhaustive. Add moved dust and response extraction
from actual images, inconclusive light fits, manual family choices, dark age/
reach/cohort boundaries, readout-mode names, validity boundaries, mixed filters,
missing metadata and physical/normalized XISF before claiming full parity.

## Expanded planning API needed

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

Add a shared core operation and C/Python binding for session-aware file planning:

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
and expanded outputs, replay, CPU/GPU fallback and cancellation before updating
the Mac dependency. Follow the Seiza processing-output version procedure for
any changed processing behavior. No processing algorithm or output version is
changed by this Mac boundary/fixture work.

Continue with the [stacking setup plan](STACKING-CALIBRATION.md).
