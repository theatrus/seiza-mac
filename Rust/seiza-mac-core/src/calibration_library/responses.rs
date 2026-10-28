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
) -> Result<(groups::Request, Vec<Source>, Value)> {
    let plans = policy::plan_flat_responses(planner.clone()).map_err(error)?;
    if !plans.unplanned.is_empty() {
        warnings.push(format!("{} flats have no capture time; measured temporal grouping is unavailable for those files.",plans.unplanned.len()));
    }
    let by_id = rows
        .iter()
        .map(|r| (r.frame.frame_uuid.clone(), r))
        .collect();
    let mut grouping = groups::Request {
        limits: plans.limits,
        night_boundaries: plans.night_boundaries,
        ..Default::default()
    };
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
    let snapshot =
        serde_json::to_value(groups::evaluate(grouping.clone()).map_err(error)?).map_err(error)?;
    Ok((grouping, sources, snapshot))
}
