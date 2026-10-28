//! Pixel I/O and caches only. Session preparation, pair requests and every
//! grouping/association decision are supplied by Seiza.
use super::*;
use seiza_calibration::flat_response::{groups, metric};

#[derive(Serialize, Deserialize)]
struct Measured {
    plane: Source,
    bin: usize,
    level: f32,
    noise: f32,
    frames: usize,
    width: usize,
    height: usize,
}
fn atomic_bytes(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    let mut file = tempfile::NamedTempFile::new_in(path.parent().unwrap()).map_err(error)?;
    file.write_all(bytes).map_err(error)?;
    file.as_file().sync_all().map_err(error)?;
    file.persist(path).map_err(error)?;
    Ok(())
}
fn measure(
    plan: &policy::FlatResponsePlan,
    rows: &BTreeMap<String, &Cached>,
    cache: &Path,
    cancel: &CancelSignal,
) -> Result<Measured> {
    let key = digest(format!("response-1-{}", plan.row.response_key));
    let memo = cache.join(format!("response-{key}.json"));
    if let Ok(data) = std::fs::read(&memo)
        && let Ok(value) = serde_json::from_slice::<Measured>(&data)
        && verify(std::slice::from_ref(&value.plane)).is_ok()
        && metric::decode_plane(&std::fs::read(&value.plane.path).map_err(error)?).is_some()
    {
        return Ok(value);
    }
    let mut binned = Vec::new();
    let mut bin = None;
    for id in &plan.sample_frames {
        check(cancel)?;
        let row = rows
            .get(id)
            .ok_or("Response sample is missing from the reviewed library")?;
        verify(&[row.source.clone(), row.processed_source.clone()])?;
        let frame = FitsFrame::open(&row.processed).map_err(error)?;
        let factor =
            metric::bin_factor(frame.image.width, frame.image.height, frame.bayer.is_some());
        if bin.is_some_and(|b| b != factor) {
            return Err("Response sample dimensions changed".into());
        }
        bin = Some(factor);
        binned.push(metric::bin_frame(
            &frame.image.data,
            frame.image.width,
            frame.image.height,
            frame.image.channels,
            factor,
        ));
    }
    check(cancel)?;
    let response = metric::build_response(&binned, bin.unwrap_or(1))
        .ok_or("Flat response could not be measured")?;
    let plane = cache.join(format!("response-{key}.bin"));
    atomic_bytes(&plane, &metric::encode_plane(&response.plane))?;
    let measured = Measured {
        plane: stamp(&plane)?,
        bin: response.bin,
        level: response.level,
        noise: response.noise,
        frames: response.frames,
        width: response.plane.width,
        height: response.plane.height,
    };
    atomic_json(&memo, &measured)?;
    Ok(measured)
}
fn corrected(row: &groups::ResponseRow, measured: &Measured) -> Result<metric::Plane> {
    verify(std::slice::from_ref(&measured.plane))?;
    let plane = metric::decode_plane(&std::fs::read(&measured.plane.path).map_err(error)?)
        .ok_or("Invalid response cache")?;
    Ok(metric::FlatResponse {
        plane,
        bin: measured.bin,
        level: measured.level,
        noise: measured.noise,
        frames: measured.frames,
    }
    .without_pedestal(row.pedestal_adu.unwrap_or(0.0) as f32))
}
pub(super) fn prepare(
    planner: &policy::Request,
    rows: &[Cached],
    cache: &Path,
    cancel: &CancelSignal,
    warnings: &mut Vec<String>,
) -> Result<Prepared> {
    let plans = policy::plan_flat_responses(planner.clone()).map_err(error)?;
    if !plans.unplanned.is_empty() {
        warnings.push(format!("{} flats have no capture time; measured temporal grouping is unavailable for those files.",plans.unplanned.len()));
    }
    let by_id = rows
        .iter()
        .map(|r| (r.frame.frame_uuid.clone(), r))
        .collect();
    let mut grouping = planner.grouping.clone();
    grouping.responses.clear();
    grouping.comparisons.clear();
    grouping.limits = plans.limits;
    grouping.night_boundaries = plans.night_boundaries;
    let mut measured = BTreeMap::new();
    let mut sources = Vec::new();
    for plan in plans.plans {
        check(cancel)?;
        let mut row = plan.row.clone();
        match measure(&plan, &by_id, cache, cancel) {
            Ok(value) => {
                row.frames = value.frames;
                row.width = Some(value.width);
                row.height = Some(value.height);
                row.bin = Some(value.bin);
                row.level_adu = Some(f64::from(value.level));
                row.noise = Some(f64::from(value.noise));
                sources.push(value.plane.clone());
                measured.insert(row.response_key.clone(), value);
            }
            Err(e) => {
                check(cancel)?;
                warnings.push(format!("Flat response {}: {e}", row.session_key));
                row.error = Some(e);
            }
        }
        grouping.responses.push(row);
    }
    let mut tried = BTreeSet::new();
    loop {
        check(cancel)?;
        let book = groups::prepare(grouping.clone()).map_err(error)?;
        let mut pending = Vec::new();
        for (a, b) in book.pairs_to_compare() {
            let (a, b) = (&book.sessions[a].row, &book.sessions[b].row);
            if tried.insert((a.response_key.clone(), b.response_key.clone())) {
                pending.push((a.clone(), b.clone()));
            }
        }
        if pending.is_empty() {
            break;
        }
        for (a, b) in pending {
            check(cancel)?;
            let (Some(ma), Some(mb)) =
                (measured.get(&a.response_key), measured.get(&b.response_key))
            else {
                continue;
            };
            let key = digest(
                serde_json::to_vec(&(
                    metric::COMPARE_ALGORITHM_VERSION,
                    &ma.plane,
                    &mb.plane,
                    a.pedestal_adu,
                    b.pedestal_adu,
                ))
                .map_err(error)?,
            );
            let memo = cache.join(format!("comparison-{key}.json"));
            let comparison: Option<metric::Comparison> = std::fs::read(&memo)
                .ok()
                .and_then(|data| serde_json::from_slice(&data).ok());
            let comparison = match comparison {
                Some(c) => Some(c),
                None => {
                    let left = corrected(&a, ma)?;
                    let right = corrected(&b, mb)?;
                    let result = metric::compare(&left, &right, ma.bin);
                    if let Some(c) = &result {
                        atomic_json(&memo, c)?;
                    }
                    result
                }
            };
            if let Some(c) = comparison {
                grouping.comparisons.push(groups::ComparisonRow {
                    earlier_key: a.response_key,
                    later_key: b.response_key,
                    broad: f64::from(c.broad),
                    dust: f64::from(c.dust),
                    sigma: f64::from(c.sigma),
                    spots: c.spots,
                    broad_x: f64::from(c.broad_x),
                    broad_y: f64::from(c.broad_y),
                    vignetting: f64::from(c.vignetting),
                    vignetting_changes: c.vignetting_changes,
                });
            } else {
                warnings.push(format!("Flat sessions {} and {} could not be compared; their relationship remains unmeasured.",a.session_key,b.session_key));
            }
        }
    }
    Ok(Prepared {
        grouping,
        sources,
        measured,
    })
}

pub(super) struct Prepared {
    pub grouping: groups::Request,
    pub sources: Vec<Source>,
    measured: BTreeMap<String, Measured>,
}
fn work_request(planner: &policy::Request, lights: &[Cached]) -> policy::FlatWorkRequest {
    policy::FlatWorkRequest {
        library: planner.clone(),
        light_context: planner
            .lights
            .iter()
            .enumerate()
            .map(|(index, meta)| {
                let found = lights
                    .iter()
                    .enumerate()
                    .find(|(_, l)| l.source.path == meta.path);
                policy::FlatLightContext {
                    light_index: index,
                    id: found.map(|(i, _)| i as i64),
                    target: found
                        .and_then(|(_, l)| l.target.clone())
                        .unwrap_or_default(),
                    ..Default::default()
                }
            })
            .collect(),
    }
}
fn read_binned(light: &Cached, cache: &Path, cancel: &CancelSignal) -> Result<metric::Plane> {
    check(cancel)?;
    verify(&[light.source.clone(), light.processed_source.clone()])?;
    let key = digest(
        serde_json::to_vec(&(
            "light-bin-1",
            &light.source,
            &light.processed_source,
            metric::RESPONSE_ALGORITHM_VERSION,
            metric::MAX_SIDE,
        ))
        .map_err(error)?,
    );
    let memo = cache.join(format!("light-bin-{key}.json"));
    if let Ok(data) = std::fs::read(&memo)
        && let Ok(source) = serde_json::from_slice::<Source>(&data)
        && verify(std::slice::from_ref(&source)).is_ok()
        && let Some(plane) = std::fs::read(&source.path)
            .ok()
            .and_then(|bytes| metric::decode_plane(&bytes))
    {
        return Ok(plane);
    }
    let frame = FitsFrame::open(&light.processed).map_err(error)?;
    let bin = metric::bin_factor(frame.image.width, frame.image.height, frame.bayer.is_some());
    let plane = metric::bin_frame(
        &frame.image.data,
        frame.image.width,
        frame.image.height,
        frame.image.channels,
        bin,
    );
    check(cancel)?;
    verify(&[light.source.clone(), light.processed_source.clone()])?;
    let path = cache.join(format!("light-bin-{key}.bin"));
    atomic_bytes(&path, &metric::encode_plane(&plane))?;
    atomic_json(&memo, &stamp(&path)?)?;
    Ok(plane)
}
fn samples(
    ids: &[i64],
    lights: &[Cached],
    cache: &Path,
    cancel: &CancelSignal,
) -> Result<Vec<metric::Plane>> {
    ids.iter()
        .map(|id| {
            let index = usize::try_from(*id).map_err(|_| "Invalid evidence light ID")?;
            read_binned(
                lights.get(index).ok_or("Evidence light ID is missing")?,
                cache,
                cancel,
            )
        })
        .collect()
}
impl Prepared {
    fn plane(&self, row: &groups::ResponseRow) -> Result<metric::Plane> {
        corrected(
            row,
            self.measured
                .get(&row.response_key)
                .ok_or("A required response plane is unavailable")?,
        )
    }
    fn evidence_key(
        &self,
        question: &impl Serialize,
        ids: &[i64],
        lights: &[Cached],
    ) -> Result<String> {
        let sources = ids
            .iter()
            .map(|id| {
                usize::try_from(*id)
                    .ok()
                    .and_then(|i| lights.get(i))
                    .map(|l| (&l.source, &l.processed_source))
                    .ok_or_else(|| "Missing evidence source".to_owned())
            })
            .collect::<Result<Vec<_>>>()?;
        digest_key(&(
            "flat-evidence-1",
            question,
            sources,
            &self.sources,
            seiza_calibration::flat_response::evidence::EVIDENCE_ALGORITHM_VERSION,
            seiza_calibration::flat_response::choice::CHOICE_ALGORITHM_VERSION,
        ))
    }
    pub(super) fn connect(
        &mut self,
        planner: &mut policy::Request,
        lights: &[Cached],
        cache: &Path,
        cancel: &CancelSignal,
        warnings: &mut Vec<String>,
    ) -> Result<policy::FlatWorkPlans> {
        use seiza_calibration::flat_response::{choice, evidence};
        planner.grouping = self.grouping.clone();
        planner.available_responses = self.measured.keys().cloned().collect();
        let initial = policy::plan_flat_work(work_request(planner, lights)).map_err(error)?;
        planner.grouping = initial.grouping;
        for question in initial.changes {
            check(cancel)?;
            if question.answered {
                continue;
            }
            let ids = question
                .filters
                .iter()
                .flat_map(|f| f.sample_lights.iter().copied())
                .collect::<Vec<_>>();
            let memo = cache.join(format!(
                "change-evidence-{}.json",
                self.evidence_key(&question, &ids, lights)?
            ));
            let cached = std::fs::read(&memo)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<groups::EvidenceRow>(&bytes).ok())
                .filter(|row| {
                    row.session_key == question.session_key && row.event_key == question.event_key
                });
            let row = if let Some(row) = cached {
                row
            } else {
                let mut fits = Vec::new();
                for filter in &question.filters {
                    check(cancel)?;
                    let before = self.plane(&filter.before)?;
                    let after = self.plane(&filter.after)?;
                    let reference = self.plane(&filter.reference)?;
                    let Some(map) = evidence::change_map(
                        &before,
                        &after,
                        &filter.vignetting_changes,
                        filter.before.bin.unwrap_or(1),
                    ) else {
                        continue;
                    };
                    let binned = samples(&filter.sample_lights, lights, cache, cancel)?;
                    let binned = binned
                        .into_iter()
                        .filter(|p| p.width == map.width && p.height == map.height)
                        .collect::<Vec<_>>();
                    let Some(background) = evidence::background(
                        &binned,
                        filter.pedestal_adu.unwrap_or(0.0) as f32,
                        filter.reference.bin.unwrap_or(1),
                    ) else {
                        continue;
                    };
                    check(cancel)?;
                    if let Some(fit) =
                        evidence::fit(&background, &reference, filter.reference_side, &map)
                    {
                        fits.push(groups::EvidenceFit {
                            filter: filter.filter.clone(),
                            targets: filter.targets.clone(),
                            lights: binned.len(),
                            carried: fit.carried,
                            spread: fit.spread.is_finite().then_some(fit.spread),
                            verdict: fit.verdict,
                        });
                    }
                }
                let result =
                    policy::finish_flat_work(policy::FlatWorkAnswer::Change { question, fits })
                        .map_err(error)?;
                let policy::FlatWorkResult::Change { row } = result else {
                    return Err("Unexpected change-evidence result".into());
                };
                atomic_json(&memo, &row)?;
                row
            };
            self.sources.push(stamp(&memo)?);
            planner.grouping.evidence.push(row);
        }
        let family_plan = policy::plan_flat_work(work_request(planner, lights)).map_err(error)?;
        planner.grouping = family_plan.grouping;
        for question in family_plan.families {
            check(cancel)?;
            if question.answered {
                continue;
            }
            let memo = cache.join(format!(
                "family-evidence-{}.json",
                self.evidence_key(&question, &question.sample_lights, lights)?
            ));
            let cached = std::fs::read(&memo)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<groups::FamilyEvidenceRow>(&bytes).ok())
                .filter(|row| {
                    row.session_key == question.session_key
                        && row.key == question.key
                        && row.target == question.target
                        && row.filter == question.filter
                });
            let row = if let Some(row) = cached {
                row
            } else {
                let representatives = question
                    .candidates
                    .iter()
                    .map(|candidate| candidate.response.as_ref())
                    .collect::<Option<Vec<_>>>();
                let mut count = 0;
                let picked = if let Some(rows) = representatives
                    && let Some(bin) = rows.first().and_then(|row| row.bin)
                {
                    let candidates = rows
                        .iter()
                        .map(|row| self.plane(row))
                        .collect::<Result<Vec<_>>>()?;
                    let binned = samples(&question.sample_lights, lights, cache, cancel)?;
                    count = binned.len();
                    if let Some(background) = evidence::background(
                        &binned,
                        question.pedestal_adu.unwrap_or(0.0) as f32,
                        bin,
                    ) {
                        check(cancel)?;
                        choice::choose_response(&background, &candidates, |a, b| {
                            question.alike.contains(&(a, b)) || question.alike.contains(&(b, a))
                        })
                    } else {
                        Default::default()
                    }
                } else {
                    warnings.push("Flat family evidence has no measured representative; its pixel choice remains unknown.".into());
                    Default::default()
                };
                let result = policy::finish_flat_work(policy::FlatWorkAnswer::Family {
                    question,
                    choice: picked,
                    lights: count,
                })
                .map_err(error)?;
                let policy::FlatWorkResult::Family { row } = result else {
                    return Err("Unexpected family-evidence result".into());
                };
                atomic_json(&memo, &row)?;
                row
            };
            self.sources.push(stamp(&memo)?);
            planner.grouping.family_evidence.push(row);
        }
        let work = policy::plan_flat_work(work_request(planner, lights)).map_err(error)?;
        planner.grouping = work.grouping.clone();
        self.grouping = work.grouping.clone();
        for state in &work.overrides {
            if let groups::OverrideStatus::Orphaned { reason } = &state.status {
                warnings.push(format!("Saved flat group choice: {reason}"));
            }
        }
        Ok(work)
    }
    pub(super) fn correct_master(
        &self,
        flat: &Built,
        planner: &policy::Request,
        lights: &[Cached],
        cache: &Path,
        cancel: &CancelSignal,
        warnings: &mut Vec<String>,
    ) -> Result<Built> {
        let work = policy::plan_flat_work(work_request(planner, lights)).map_err(error)?;
        if work.corrections.is_empty() {
            return Ok(flat.clone());
        }
        if work.corrections.len() != 1
            || work.corrections[0].light_indices.len() != planner.lights.len()
        {
            return Err(
                "The executed flat correction no longer shares one calibration session".into(),
            );
        }
        let plan = &work.corrections[0];
        let before = self
            .measured
            .get(&plan.before.response_key)
            .ok_or("The correction's before response is missing")?;
        let after = self
            .measured
            .get(&plan.after.response_key)
            .ok_or("The correction's after response is missing")?;
        let sources = [
            flat.source.clone(),
            before.plane.clone(),
            after.plane.clone(),
        ];
        verify(&sources)?;
        check(cancel)?;
        let key = digest_key(&(
            &sources,
            &plan.correction,
            plan.bin,
            metric::CHANGE_MAP_ALGORITHM_VERSION,
            seiza_stacking::OUTPUT_VERSION,
        ))?;
        let path = cache.join(format!("corrected-flat-{key}.fits"));
        let memo = path.with_extension("json");
        if let Ok(data) = std::fs::read(&memo)
            && let Ok(built) = serde_json::from_slice::<Built>(&data)
            && built.source.path == path
            && verify(std::slice::from_ref(&built.source)).is_ok()
        {
            return Ok(built);
        }
        let map = metric::change_map(&self.plane(&plan.before)?, &self.plane(&plan.after)?)
            .ok_or("The required correction map could not be measured")?;
        let mut frame = FitsFrame::open(&flat.source.path).map_err(error)?;
        metric::apply_change_map(
            &mut frame.image.data,
            frame.image.width,
            frame.image.channels,
            &map,
            plan.bin,
            plan.divide,
        );
        check(cancel)?;
        verify(&sources)?;
        // Preserve the source master's acquisition/optical metadata and flags.
        publish_frame(&path, &frame)?;
        let note = format!(
            "Applied Seiza's flat correction {} across the measured change.",
            plan.correction.key
        );
        warnings.push(note.clone());
        let mut built = flat.clone();
        built.source = stamp(&path)?;
        built.warnings.push(note);
        atomic_json(&memo, &built)?;
        Ok(built)
    }
    pub(super) fn group_edges(&self) -> Result<Vec<Value>> {
        let book = groups::prepare(self.grouping.clone()).map_err(error)?;
        let mut edges = Vec::new();
        for family in &book.families {
            for pair in family.sessions.windows(2) {
                let before = &book.sessions[pair[0]].row;
                let after = &book.sessions[pair[1]].row;
                let label = format!(
                    "{} · {} · {} → {}",
                    family.filter.as_deref().unwrap_or("Unknown filter"),
                    family
                        .rotation
                        .map(|a| format!("{a:.1}°"))
                        .unwrap_or_else(|| "Unknown angle".into()),
                    before.night,
                    after.night
                );
                let row = groups::GroupOverrideRow {
                    anchor_frame: after
                        .frame_uuids
                        .first()
                        .cloned()
                        .ok_or("Flat session has no anchor")?,
                    session_key: after.session_key.clone(),
                    family_key: after.family_key.clone(),
                    rig_uuid: after.rig_uuid.clone(),
                    choice: None,
                    before_frame: before.frame_uuids.first().cloned(),
                    before_session_key: Some(before.session_key.clone()),
                    label: label.clone(),
                    chosen_at: 0,
                    night: Some(after.night.clone()),
                    before_night: Some(before.night.clone()),
                    rotation: after.rotation,
                    before_rotation: before.rotation,
                };
                edges.push(json!({"id":after.session_key,"label":label,"row":row}));
            }
        }
        Ok(edges)
    }
    pub(super) fn light_options(&self, lights: &[Cached]) -> Result<Vec<Value>> {
        let book = groups::prepare(self.grouping.clone()).map_err(error)?;
        Ok(lights.iter().map(|light| {
            let changes=book.events_for(&light.light.rig_uuid,light.light.filter.as_deref()).map(|event|json!({"key":event.key,"start":event.start,"end":event.end,"rig_uuid":event.rig_uuid})).collect::<Vec<_>>();
            let mut groups=Vec::new();
            for family in book.families.iter().filter(|f|f.rig_uuid==light.light.rig_uuid) {
                for (index,group) in family.groups.iter().enumerate() {
                    if let Some(row)=group.first().map(|i|&book.sessions[*i].row) {
                        groups.push(json!({"frame":row.frame_uuids.first(),"session_key":row.session_key,"label":format!("{} · {:.1}° · group {}",family.filter.as_deref().unwrap_or("Unknown filter"),family.rotation.unwrap_or(0.0),index+1)}));
                    }
                }
            }
            json!({"path":light.source.path,"fingerprint":light.source.fingerprint,"guid":light.frame.frame_uuid,"rig_uuid":light.light.rig_uuid,"changes":changes,"groups":groups})
        }).collect())
    }
}
fn digest_key(value: &impl Serialize) -> Result<String> {
    Ok(digest(serde_json::to_vec(value).map_err(error)?))
}
