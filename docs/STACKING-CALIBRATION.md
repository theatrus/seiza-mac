# Plan calibration in stacking setup

Status: **Setup design proposed; native boundary foundations implemented.**
Baseline: Mac main `d063c9b` (PR #91).
The existing app still prepares one calibration set per output. This feature
replaces that restriction with an explicit assignment for every selected light,
for both Fixed reference and Expanded mosaic.

## What the user should be able to do

Open lights from images, folders, or TXT/CSV lists; choose a calibration library;
grade its frames, group compatible sets, and review which calibration each light
will receive. Build or reuse the required masters and stack the original lights
onto the chosen canvas. A mosaic may contain several calibration sessions without
being split into separate output images just because its flats or darks differ.

The first implementation slice adds captured PSF Guard reference fixtures,
native bias/dark screening wrappers, and session integration/checkpoint/replay
tests. The [native boundary audit](STACKING-CALIBRATION-BOUNDARY.md) records what
is verified and the shared-policy/expanded-planning APIs still needed. The new
setup workflow remains proposed; these foundations do not enable it.

PSF Guard is the behavior reference. Its library grades and measured flat groups,
per-light explanations, master selection, and session assignments should produce
the same decisions for equivalent inputs and settings. Sharing only its pixel
measurement functions would not establish matching parity.

The first delivery belongs in **Stack Images**. It includes fixed and expanded
canvases together. Moving live acquisition to the same planner is a follow-up;
the initial feature must not change active live-stack sessions.

## The four kinds of group

| Group | What it decides |
| --- | --- |
| Output group | Which lights form one output/filter/canvas. Optional sky-panel analysis can help select these lights. |
| Grading peers | Which raw calibration frames can be compared fairly for quality. |
| Flat response group | Which flat sessions describe sufficiently similar optical response, including measured changes between sessions. |
| Calibration session | Which lights resolve to the same exact master recipes and effective matching policy. One output can contain many sessions. |

Folders, CSV row order, and sky-panel labels do not define calibration sessions.
Different nights can share a recipe; lights in one folder can need different
recipes. Session identity follows the selected sources and matching policy.

## Stack setup

Keep **Stacking mode** and light selection first. Expand **Calibration** into a
preparation workspace with three sources:

- **Automatic library**: grade, group, match, and generate masters.
- **Existing masters**: assign supplied masters and validate their compatibility;
  existing masters are not graded as raw calibration frames.
- **Off**: stack without applying calibration.

Automatic library offers one or more folders and reuses the app's local index,
measurements, grades, choices, and generated masters. Keep it a native folder
workflow; using PSF Guard's database is not a prerequisite.

```text
Stacking mode       Fixed reference | Expanded mosaic
Frames              1,240 selected · Ha and OIII · 2 outputs

Calibration         Automatic library
Library             /Astro/Calibration                  Add…
                    Analyze Calibration                Refresh

Library             80 OK · 6 Suspect · 4 Poor · 2 Ungraded
Flat groups         3 measured groups · 1 unresolved change
Light coverage      1,210 matched · 30 incomplete
Master plan         8 reusable · 3 to build

[Calibration Frames] [Flat Groups] [Light Matches] [Masters]

Incomplete lights   Keep with warnings | Exclude | Stop
                    Review details…

                    Choose Output, Build Masters and Stack…
```

The numbers above illustrate the layout, not a limit or a fixed relationship
between quality grades and matching outcomes. A compact summary can remain in
the setup dialog; the four inspectors can open in a resizable review sheet.

### Analyze and review

**Analyze Calibration** runs discovery, header inspection, measurement/grading,
flat-response grouping, and per-light matching off the main thread. Show the
current stage, counts, cancellation, and any inaccessible source folders. Reuse
current measurements rather than rereading unchanged files.

The inspectors provide:

1. **Calibration Frames**: kind, rig/sensor settings, exposure, temperature,
   night, grade, findings, measured values and limits, and whether each frame is
   in use. Offer **Keep out**, **Use anyway**, and **Clear choice**.
2. **Flat Groups**: filter, sensor/optical identity, sessions, response comparisons,
   changes, and any uncertainty. Show the evidence behind a family assignment.
   Support the applicable PSF Guard split/join and light-assignment choices.
3. **Light Matches**: output, source path, capture session, assigned recipe,
   effective matching settings, and coverage status. **Why this match?** shows
   selected sources, compatible-but-unused alternatives, exclusions, and reasons
   for missing calibration. Selecting a panel or folder only narrows this view.
4. **Masters**: bias, dark, dark-flat and flat recipes, selected input counts,
   grades/overrides, dependencies, cache status, predicted set findings, and
   every light/session/output they will serve. Inspect built masters without
   rebuilding them merely to show a preview.

Allow choosing where inputs or managed caches live without changing raw files.
Remember folder access with security-scoped bookmarks and retain access for each
running analysis/build. A missing volume is unavailable evidence, not an empty
library or a failed quality grade.

### Starting a stack

Review source selection and coverage before master generation. The final action
chooses the output location, builds or reuses the dependency graph, and starts
integration using the reviewed assignments. Show build progress by master and
stage. Recheck file identities before publishing masters and using the plan.

Use the same missing-calibration policy as PSF Guard: **Keep with warnings** is
the proposed default, with **Exclude** and **Stop** available in setup. Show
exactly which correction each retained light will receive. This policy does not
make an incompatible master acceptable. A build failure that changes a reviewed
assignment returns the affected entries to setup for review; it must not silently
turn a fully calibrated plan into a partly raw stack.

Do not require repeated warning dialogs for an unchanged, reviewed plan. Changes
to selected lights, library contents, choices, grouping, or settings invalidate
the affected plan and its coverage summary before another stack can use it.

## Grading, grouping, and matching policy

### Frame grades

Use Seiza's native bias/dark measurements and bias/dark/flat screening with the
same peer grouping and effective limits as PSF Guard:

- **OK** stays in use.
- **Suspect** stays in use and carries findings into coverage and master review.
- **Poor** stays out unless the user chooses **Use anyway**.
- **Ungraded**, stale, unreadable, and insufficient evidence remain distinct
  states. PSF Guard allows ungraded candidates; do the same while reporting that
  evidence is incomplete. Do not label them OK or silently discard them.

Bias/dark/dark-flat peers use compatible sensor settings and the applicable
exposure/temperature rules. Flat peers use their capture session, filter, sensor
and optical configuration. Dark-current, clipping, banding, noise, illumination,
and changing-feature findings must retain native units and provenance. A steady
dust shadow is not automatically a bad flat.

Quality choices never bypass hard sensor compatibility, valid exposure scaling,
or safe pedestal removal. User choices survive regrading and rescans. A change
to peer membership reruns screening from stored measurements as appropriate.
Changed algorithm versions or file contents invalidate the measurements too.

### Flat groups and session choice

Target PSF Guard's measured-response workflow, not only a night/rotation bucket:
build comparable flat-session responses, compare dust/vignetting/illumination,
form response families, identify changes, and determine which side a light
belongs to. Retain the distinction between measured evidence and recorded angles.
Unknown or inconclusive evidence follows PSF Guard's documented fallback and
Check status; it must not be presented as a proven match.

Carry the selected family's effective light rotation and any supported correction
recipe through matching, calibration, cache identity, and replay. The same applies
to explicit family/group choices. A user quality override alone is not evidence
that different optical responses are interchangeable.

### Match each light, then combine identical recipes

Match against header-derived sensor and optical signatures, including supported
readout-mode names, filter, exposure, temperature and time/validity rules. Preserve
PSF Guard's unknown-field rules and filter normalization. A filename can supply
an explicitly recorded filter fallback where the current Mac workflow permits
one; directory names alone do not establish a match.

Include the complete-set preference for bias/dark cohorts, dark age/reach rules,
flat age checks and validity boundaries. Resolve defaults and per-rig overrides
through the shared policy; do not duplicate numerical thresholds in Swift.

For each light, produce a deterministic selection and explanation. Partition
lights by identical resulting master recipes and effective gates. Verify every
member against its recipe before building. Do not search for one compromise set
that must serve the entire mosaic, or let the first light choose everyone else's
flats. Calibration session count does not increase output count.

### Build a reusable master dependency graph

Deduplicate recipes across outputs and sessions. Build bias, dark, dark-flat and
flat masters in dependency order with the native rejection, normalization,
pedestal and defect-processing behavior used by PSF Guard. Use at least the native
minimum input counts and preserve set/master findings as well as frame grades.
Where PSF Guard supports a flat with a pedestal fitted from its lights, retain the
fit, evidence and applied pedestal in the session recipe. An inconclusive fit is
not permission to divide uncorrected lights by a flat.

Cache identity includes source identities/content, upstream master identities,
build/output algorithm versions, relevant processing settings and any measured
response/correction used. Changing a bias or dark-flat invalidates dependent
masters and plans transitively. A quality change that leaves the effective input
set and build settings unchanged need not rebuild identical pixels.

Publish atomically and lease masters against pruning while any plan, integration
or replay needs them. Account for all retained master buffers, the expanded canvas,
working frames and scratch disk within the job's resource budget. Do not assume
that every session's full-resolution masters can remain resident at once.

## Carry the assignments through stacking

Every planned light has a stable identity, output membership, calibration session,
master recipe, effective matching policy, calibration state and explanation.
Keep the original light order/reference policy: regrouping for master generation
must not reorder an online rejection algorithm's inputs.

For each input, load/select its session's masters and gate, validate the actual
light, calibrate raw samples before demosaicing or registration, then integrate
into the output's common canvas. Record the applied recipe and outcome per frame.
Already calibrated inputs need an explicit state and must not be calibrated twice.

### Expanded mosaics

The canvas planner must see reference/overlap samples prepared with the same
session calibration the corresponding original light will receive. Planning raw
geometry/photometry under one set and switching masters only during integration
is insufficient. Seiza 0.46.0 provides
`seiza_live_stacker_open_fits_expanding_sessions` for this operation. Adapt the
host's planned sessions to that file-input API, preserving each light's complete
gate, scaling and pedestal recipe during planning, integration and replay.

The final mosaic integrates each original eligible light once with its own recipe.
Do not independently stack calibration groups and stitch those intermediate
stacks: that changes rejection, weighting and exposure statistics. Sky-panel
analysis stays optional, including for mixed-session CSV imports.

Transient-removal reintegration must reload every frame under its recorded master
files, scaling and gate. Checkpoints, if used, need the same information; restoring
only the currently active calibration set cannot reproduce a multi-session run.
Changed/missing masters or sources invalidate replay explicitly. Scratch reference
files are not substitutes for the original-light ledger and must not be counted
as exposures.

## Share the implementation with PSF Guard

Both dependency-adoption PRs now use the published Seiza **0.46.0** release,
calibration **0.10.0** and stacking **0.53.0**. The Mac reaches them through
C ABI **0.46.0**, with the complete matching published header. Seiza #385 moved
PSF Guard's reusable grouping, grading, selection, master and flat-retry policy
into the core. The Mac host still needs to adapt its library records and execute
the returned plans before enabling the new setup controls.

| Capability | Available foundation | Planned work |
| --- | --- | --- |
| Measure and screen calibration frames | C ABI measurement/screening exports; Mac flat review | Typed Mac models for all kinds, peer grouping and persistent grading/choices |
| Metadata matching and master building | Native matcher/planner/build APIs and Mac cache/leases | Match per light; deduplicate recipes across sessions and outputs |
| Complete acquisition signatures | PSF Guard host records and the native frame probe | Audit missing fields such as readout-mode names and expose shared normalization without weakening matching |
| Measured flat families and change-aware choice | Shared `flat_group_plan`, prepared groups and calibration-library policy in Seiza 0.46.0 | Adapt cached host records and verify full planner decisions against the reference captures |
| Master/gate changes during integration | Native path-based master swaps, tolerance and light-rotation setters | Typed session application and per-light provenance/replay tests |
| Multi-session expanded planning | Published `open_fits_expanding_sessions` C ABI with immutable per-light assignments | Wire the host executor and prove fixed/expanded output, checkpoint and replay parity |

Keep pixel algorithms and reusable matching/grouping policy in Seiza crates. Keep
file discovery, bookmarks, local persistence, jobs and UI in the Mac host. Adapt
PSF Guard's records to shared policy rather than making Swift reproduce its SQL
queries or copying the matcher into `Rust/seiza-mac-core`.

For every missing shared capability, extend the core, C ABI and Python together,
add binding-parity coverage, then update both hosts to the published contract.
Follow Seiza's output-version tests before changing processing behavior. Add
cross-host fixtures so equivalent records, settings and choices yield the same
grades, effective sources, sessions and master recipes.

## Implementation sequence

1. **Freeze parity fixtures and audit the native boundary.** Capture PSF Guard's
   grades, peer/response groups, selections, explanations and session recipes for
   representative libraries. Prove differing-session calibration and replay
   through the current C ABI, including an expanded canvas. Identify exact API
   gaps before choosing bridge changes or claiming full parity.
2. **Add the reusable local library.** Index headers/file identities and store
   measurements separately from grades, group decisions and user choices. Add
   versioned persistence, scoped folder access, incremental refresh and cancellable
   jobs. Reuse existing master caches and leases where their contracts suffice.
3. **Share and expose grading/grouping/matching policy.** Implement native parity
   tests for raw quality, measured flat families, time/validity policies and
   per-light session assignments. Make unavailable evidence visible in the plan.
4. **Build and execute the session plan.** Add the master dependency graph,
   shared-canvas planning, per-light calibration/gates and replay provenance.
   Fixed and expanded canvas modes must both pass before enabling the feature.
5. **Add the stacking-setup review.** Implement Analyze Calibration, the four
   inspectors, persisted choices, coverage policy and Build Masters and Stack.
   Connect changes to deterministic plan invalidation and progress/cancellation.
6. **Validate and enable.** Compare decisions and pixels with PSF Guard, check
   both containers/sample domains and CPU/GPU fallback, and document actual
   remaining parity differences. Metadata-only matching is an intermediate
   milestone, not completion of the requested PSF Guard workflow.

## Acceptance cases

- One output combines two nights/two panels requiring different flats and darks;
  each light gets the correct recipe, in both fixed and expanded modes. No common
  flat suitable for both nights is required.
- Equivalent PSF Guard/Mac inputs produce the same grades, excluded sources,
  coherent cohorts, flat families, session assignments and master recipes.
- Poor calibration frames are omitted by default; suspect/ungraded states and
  persisted choices follow the shared policy without bypassing hard matching.
- Moved dust, unlike flat sessions, missing/incorrect angles and inconclusive
  light evidence produce the expected family/side choice and Check explanation.
- Multiple filters/outputs reuse shared bias/dark masters while keeping incompatible
  flats separate. A session shared by two outputs is built only once.
- Changed files, grades, choices, limits or dependencies invalidate the affected
  plan/cache; unchanged inputs reuse current measurements and masters.
- Missing calibration and build failures obey the reviewed Keep/Exclude/Stop
  policy with exact counts and corrections applied. Nothing silently changes a
  reviewed assignment or overwrites an original.
- Reintegration reproduces the per-frame calibration even after session switches;
  A→B→A does not lose recipes, duplicate lights or retain the wrong gate. Missing
  sources/masters and modified files fail with an actionable explanation.
- A CSV of more than 512 lights spanning folders, nights and calibration sessions
  can plan and stack without sky-panel analysis. Large libraries remain cancellable
  and bounded by memory/scratch budgets, not a replacement frame-count cap.
- FITS/XISF, normalized and physical sample domains, mono/CFA, already calibrated
  inputs, alias paths, removed volumes, cancellation/restart, and cache pruning
  while a stack is running have regression coverage.

## Evidence used for this plan

PSF Guard was inspected at `79f5e31d53b8371e8fcd0b22a9b69692412cd8b4`:

- [Calibration grades, groups, matching and master generation](https://github.com/theatrus/psf-guard/blob/79f5e31d53b8371e8fcd0b22a9b69692412cd8b4/docs/CALIBRATION_LIBRARY.md).
- [Selection, master recipes and per-light session assignments](https://github.com/theatrus/psf-guard/blob/79f5e31d53b8371e8fcd0b22a9b69692412cd8b4/src/calibration.rs).
- [Grading policy and native screening](https://github.com/theatrus/psf-guard/blob/79f5e31d53b8371e8fcd0b22a9b69692412cd8b4/src/calibration/quality.rs).
- [Calibrated mosaic references and resource accounting](https://github.com/theatrus/psf-guard/blob/79f5e31d53b8371e8fcd0b22a9b69692412cd8b4/src/server/stack_preview/mosaic.rs).

Mac foundations: [preparation service](../App/CalibrationPreparationService.swift),
[stack driver/setup](../App/ImageStacker.swift), [published C ABI](../Shared/seiza_cabi.h),
and [current mosaic behavior](MOSAIC-STACKING.md). Existing guides describe shipped
behavior; this document describes the proposed replacement.
