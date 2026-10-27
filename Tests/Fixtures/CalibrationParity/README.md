# Calibration parity reference

`psf-guard.json` is captured from PSF Guard revision
`79f5e31d53b8371e8fcd0b22a9b69692412cd8b4`, using its published Rust API,
Seiza calibration 0.8.1 and stacking 0.51.2. It contains synthetic data only.
The capture never opens a user catalog or changes source images.

Run from the Mac checkout, with Python 3.11+ and the pinned PSF Guard checkout:

```sh
python3 scripts/capture-calibration-parity.py /path/to/psf-guard
```

The script checks the revision, tracked source changes and locked Seiza
versions. It builds a temporary Rust executable against the actual PSF Guard
library, reusing that checkout's Cargo target cache. All input FITS, SQLite
catalogs and generated masters live in temporary directories. It needs the
checkout's normal build prerequisites, including its embedded frontend assets,
and cached Cargo dependencies (`--offline`). The script does not regenerate
those assets. Use `--output /tmp/psf-guard.json` to compare a fresh capture
without replacing the committed fixture.

The harness generates FITS data and serializes public API results; it does not
implement matching or screening. Snake-case measurement keys are converted to
the C ABI's camelCase. Paths become stable basenames; random catalog IDs, cache
paths and file-dependent fingerprints are omitted. The fallback fingerprint is
a stable policy value and remains in the capture.

## Captured cases

| Case | Reference evidence |
| --- | --- |
| Different gains | Separate bias cohorts, per-light selections, A→B→A assignments, built master counts/recipe kinds, effective gates, identity unchanged by reordering |
| Dark contaminated by light | Ungraded selection, native measurement/grade and exclusion explanation, selected/kept-out sources, Use anyway, regrading, clearing the choice |
| Clipped flat | Raw measurements and per-frame grades/main finding codes; three OK, one Poor |
| Measured flat families | Three explicit response records and pair metrics; alike 0°/90° sessions share a family/group, a changed response makes another group/event, and time placement retains uncertainty inside the change window |
| Failed automatic preparation | Unavailable automatic plan remains distinct from explicit Off |

The flat-family case supplies measured response records directly to PSF Guard's
pure `Book` API. It freezes grouping/placement policy, not extraction of those
metrics from pixels. Explicit limits and synthetic metrics are fixture inputs,
not defaults to copy into the Mac app.

## What the Mac tests establish

`CalibrationParityTests` compares native bias/dark/flat screening against the
captured PSF Guard grades and finding codes, and verifies physical-ADU bias
measurement and lossless stored measurements. Peer sets in this fixture are
explicitly partitioned by kind/gain; this is not a general grouping algorithm.

`CalibrationSessionBoundaryTests` independently exercises the published C ABI
with different biases, flats, gains and recorded/measured rotations. A→B→A
integration, wrong-master refusal, a saved context, per-pixel replay, source
protection and a missing historical master are checked on fixed and expanded
canvases. Expanded input panels have different footprints. Its planner is
deliberately opened **without calibration**: this tests integration and replay,
and does not establish correct multi-session reference planning. Prepared-array
mode is also tested as an unsuitable replacement for the file-input path.

The selections, override transitions, recipes, gates and flat-family decisions
are reference evidence for the future shared planner. The current Mac app does
not run those PSF Guard policies. Do not label these fixtures as complete host
parity or enable a new setup mode based on these tests alone. See the
[native boundary audit](../../../docs/STACKING-CALIBRATION-BOUNDARY.md).
