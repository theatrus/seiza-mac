//! Run only against a temporary synthetic catalog. No user database is opened.
use anyhow::Result;
use psf_guard::calibration as quality;
use psf_guard::calibration::{self, CalibrationMode};
use psf_guard::commands::import::headers::read_frame_meta;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

fn frame(
    root: &Path,
    name: &str,
    kind: &str,
    gain: i32,
    level: i32,
    index: usize,
) -> Result<PathBuf> {
    let exposure = match kind {
        "BIAS" => 0,
        "FLAT" => 2,
        _ => 300,
    };
    let mut bytes = Vec::new();
    for card in [
        "SIMPLE  =                    T".into(),
        "BITPIX  =                   16".into(),
        "NAXIS   =                    2".into(),
        "NAXIS1  =                   64".into(),
        "NAXIS2  =                   64".into(),
        "BZERO   =                32768".into(),
        format!("IMAGETYP= '{kind}'"),
        format!("GAIN    = {gain:20}"),
        format!("EXPTIME = {exposure:20}"),
        "OFFSET  =                   20".into(),
        "XBINNING=                    1".into(),
        "YBINNING=                    1".into(),
        "CCD-TEMP=                  -10".into(),
        "INSTRUME= 'ParityCam'".into(),
        "TELESCOP= 'ParityScope'".into(),
        "FILTER  = 'Ha'".into(),
        format!("DATE-OBS= '2026-09-11T03:00:{index:02}'"),
        "END".into(),
    ] {
        let mut card = card.into_bytes();
        card.resize(80, b' ');
        bytes.extend(card);
    }
    bytes.resize(bytes.len().div_ceil(2880) * 2880, b' ');
    for y in 0..64 {
        for x in 0..64 {
            let noise = ((x * 17 + y * 31 + index * 13) % 7) as i32 - 3;
            bytes.extend((((level + noise).clamp(0, 65535) - 32768) as i16).to_be_bytes());
        }
    }
    bytes.resize(bytes.len().div_ceil(2880) * 2880, 0);
    let path = root.join(name);
    std::fs::write(&path, bytes)?;
    Ok(path)
}

fn names(frames: &[calibration::CalibrationFrame]) -> Vec<String> {
    let mut names: Vec<_> = frames
        .iter()
        .map(|f| {
            f.source_path
                .file_name()
                .unwrap()
                .to_str()
                .unwrap()
                .to_owned()
        })
        .collect();
    names.sort();
    names
}

fn selection(conn: &Connection, light: &Path) -> Result<Value> {
    let selected = calibration::select_for_light(conn, &read_frame_meta(light))?;
    Ok(
        json!({"bias": names(&selected.bias), "dark": names(&selected.dark),
        "flat": names(&selected.flat), "darkFlat": names(&selected.dark_flat),
        "keptOut": names(&selected.kept_out)}),
    )
}

// C ABI records use camelCase, PSF Guard stores the native snake_case record.
fn camel(value: Value) -> Value {
    match value {
        Value::Object(fields) => Value::Object(
            fields
                .into_iter()
                .map(|(key, v)| {
                    let mut parts = key.split('_');
                    let mut key = parts.next().unwrap().to_owned();
                    for p in parts {
                        let mut c = p.chars();
                        if let Some(first) = c.next() {
                            key.extend(first.to_uppercase());
                            key.push_str(c.as_str());
                        }
                    }
                    (key, camel(v))
                })
                .collect(),
        ),
        Value::Array(v) => Value::Array(v.into_iter().map(camel).collect()),
        v => v,
    }
}

fn run_case(root: &Path, mixed_gains: bool) -> Result<Value> {
    std::fs::create_dir(root)?;
    let mut conn = Connection::open_in_memory()?;
    let mut paths = Vec::new();
    for gain in if mixed_gains {
        vec![100, 200]
    } else {
        vec![100]
    } {
        for index in 0..3 {
            paths.push(frame(
                root,
                &format!("bias-{gain}-{index}.fits"),
                "BIAS",
                gain,
                500,
                index,
            )?);
        }
        if !mixed_gains {
            for index in 0..4 {
                paths.push(frame(
                    root,
                    &format!("dark-{index}.fits"),
                    "DARK",
                    gain,
                    if index == 3 { 900 } else { 503 },
                    index + 10,
                )?);
            }
        }
    }
    let metadata: Vec<_> = paths.iter().map(|p| read_frame_meta(p)).collect();
    let tx = conn.transaction()?;
    calibration::import_calibration_frames(&tx, &metadata, Some("parity"))?;
    tx.commit()?;
    let light_a = frame(root, "light-a.fits", "LIGHT", 100, 1100, 30)?;
    let light_b = frame(
        root,
        "light-b.fits",
        "LIGHT",
        if mixed_gains { 200 } else { 100 },
        1100,
        31,
    )?;
    let ungraded = selection(&conn, &light_a)?;
    quality::measure_and_grade(&conn)?;
    let details = calibration::library_details(&conn)?;
    let mut frames = Vec::new();
    for f in &details.frames {
        let stored: String = conn.query_row("SELECT measurement_json FROM psf_guard_calibration_frame_quality WHERE frame_uuid = ?1", [&f.frame_uuid], |r| r.get(0))?;
        let mut measurement: Value = serde_json::from_str(&stored)?;
        measurement.as_object_mut().unwrap().remove("type");
        frames.push(
            json!({"name": Path::new(&f.source_path).file_name().unwrap().to_str().unwrap(),
            "kind": f.kind.as_str(), "gain": f.gain, "measurement": camel(measurement),
            "grade": f.quality.grade, "gradeCode": f.quality.grade_code,
            "keptOutReason": f.kept_out}),
        );
    }
    frames.sort_by_key(|f| f["name"].as_str().unwrap().to_owned());
    let selected_a = selection(&conn, &light_a)?;
    let selected_b = selection(&conn, &light_b)?;
    let lights = vec![light_a.clone(), light_b.clone(), light_a.clone()];
    let plan = calibration::resolve_or_build_master_plan(
        &conn,
        &root.join("cache"),
        &lights,
        None,
        None,
        CalibrationMode::Auto,
        &[],
    )?;
    let reverse = calibration::resolve_or_build_master_plan(
        &conn,
        &root.join("cache"),
        &[light_b, light_a.clone(), light_a],
        None,
        None,
        CalibrationMode::Auto,
        &[],
    )?;
    let mut result = json!({"name": if mixed_gains { "different-gains" } else { "dark-leak" },
        "frames": frames, "ungradedSelection": ungraded, "lightSelections": [selected_a, selected_b],
        "assignments": plan.assignments, "sessionCount": plan.sessions.len(),
        "sessions": plan.sessions.iter().map(|s| json!({
            "biasFrames": s.applied.bias_frames, "darkFrames": s.applied.dark_frames,
            "darkFlatFrames": s.applied.dark_flat_frames, "flatFrames": s.applied.flat_frames,
            "recipeKind": match &s.recipe {
                calibration::MasterRecipe::None => "none",
                calibration::MasterRecipe::Files {..} => "files",
                calibration::MasterRecipe::PedestalFlat {..} => "pedestal-flat",
            }, "gate": s.match_tolerances,
        })).collect::<Vec<_>>(),
        "sessionStates": plan.sessions.iter().map(|s| s.applied.state.as_str()).collect::<Vec<_>>(),
        "reorderedIdentityEqual": plan.applied.fingerprint == reverse.applied.fingerprint});
    if !mixed_gains {
        let bad = details
            .frames
            .iter()
            .find(|f| f.source_path.ends_with("dark-3.fits"))
            .unwrap();
        quality::set_overrides(
            &conn,
            &[bad.frame_uuid.clone()],
            Some(quality::QualityOverride::Use),
        )?;
        result["useAnywaySelection"] = selection(&conn, &lights[0])?;
        quality::grade_library(&conn)?;
        result["regradedUseAnywaySelection"] = selection(&conn, &lights[0])?;
        quality::set_overrides(&conn, &[bad.frame_uuid.clone()], None)?;
        result["clearedSelection"] = selection(&conn, &lights[0])?;
    }
    Ok(result)
}

fn flat_quality(root: &Path) -> Result<Value> {
    std::fs::create_dir(root)?;
    let mut conn = Connection::open_in_memory()?;
    let paths = (0..4)
        .map(|i| {
            frame(
                root,
                &format!("flat-{i}.fits"),
                "FLAT",
                100,
                if i == 3 { 65535 } else { 30000 },
                i,
            )
        })
        .collect::<Result<Vec<_>>>()?;
    let metadata: Vec<_> = paths.iter().map(|p| read_frame_meta(p)).collect();
    let tx = conn.transaction()?;
    calibration::import_calibration_frames(&tx, &metadata, Some("parity"))?;
    tx.commit()?;
    quality::measure_and_grade(&conn)?;
    let mut details = calibration::library_details(&conn)?.frames;
    details.sort_by(|a, b| a.source_path.cmp(&b.source_path));
    let mut measurements = Vec::new();
    for f in &details {
        let stored: String = conn.query_row("SELECT measurement_json FROM psf_guard_calibration_frame_quality WHERE frame_uuid = ?1", [&f.frame_uuid], |r| r.get(0))?;
        let mut m: Value = serde_json::from_str(&stored)?;
        m.as_object_mut().unwrap().remove("type");
        measurements.push(camel(m));
    }
    Ok(json!({"name": "clipped-flat", "measurements": measurements,
        "grades": details.iter().map(|f| &f.quality.grade).collect::<Vec<_>>(),
        "gradeCodes": details.iter().map(|f| &f.quality.grade_code).collect::<Vec<_>>() }))
}

fn flat_groups() -> Value {
    use calibration::flat_groups::measure::{
        model::{Book, Limits},
        rows::{ComparisonRow, ResponseRow},
    };
    let day = 86400;
    let responses: Vec<_> = [("a", 0.0, 0), ("b", 90.0, 3 * day), ("c", 90.0, 6 * day)]
        .into_iter()
        .map(|(key, rotation, at)| ResponseRow {
            response_key: key.into(),
            session_key: format!("s-{key}"),
            rig_uuid: "rig".into(),
            family_key: "rig-ha-sensor".into(),
            night: String::new(),
            filter: Some("Ha".into()),
            rotation: Some(rotation),
            frame_uuids: (0..3).map(|i| format!("{key}-{i}")).collect(),
            frames: 3,
            captured_first: Some(at),
            captured_last: Some(at + 600),
            level_adu: Some(30000.0),
            pedestal_adu: Some(500.0),
            noise: Some(0.0003),
            width: Some(100),
            height: Some(80),
            bin: Some(10),
            algorithm_version: 1,
            error: None,
            unread: vec![],
        })
        .collect();
    let metrics = [("a", "b", 0.002), ("a", "c", 0.03), ("b", "c", 0.03)];
    let comparisons = metrics
        .iter()
        .map(|(a, b, dust)| ComparisonRow {
            earlier_key: (*a).into(),
            later_key: (*b).into(),
            broad: 0.001,
            dust: *dust,
            sigma: 0.0002,
            spots: vec![],
            broad_x: 0.5,
            broad_y: 0.5,
            vignetting: 0.0,
            vignetting_changes: vec![],
        })
        .collect();
    let book = Book::build(responses.clone(), comparisons, vec![], vec![], |_| Limits {
        measured: true,
        dust: 0.01,
        broad: 0.02,
        window: day,
        rotation: 2.0,
    });
    let placements: Vec<_> = book
        .events
        .iter()
        .map(|event| {
            json!({
                "before": book.place(event, 2 * day), "during": book.place(event, 4 * day),
                "after": book.place(event, 7 * day),
            })
        })
        .collect();
    json!({"name": "measured-alike-angles-then-change", "responses": responses,
        "comparisonDust": metrics, "broad": 0.001, "sigma": 0.0002,
        "limits": {"dust": 0.01, "broad": 0.02, "window": day, "rotation": 2.0},
        "families": book.families, "boundaries": book.boundaries,
        "events": book.events, "placements": placements})
}

fn main() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let fallback = calibration::CalibrationPlan::without_calibration(3);
    let result = json!({"schemaVersion": 1,
        "psfGuardRevision": "79f5e31d53b8371e8fcd0b22a9b69692412cd8b4",
        "calibrationVersion": "0.8.1", "stackingVersion": "0.51.2",
        "cases": [run_case(&temp.path().join("gains"), true)?, run_case(&temp.path().join("leak"), false)?],
        "flatQuality": flat_quality(&temp.path().join("flats"))?, "flatGroups": flat_groups(),
        "unavailablePlan": {"assignments": fallback.assignments, "state": fallback.applied.state,
            "fingerprint": fallback.applied.fingerprint, "mode": fallback.applied.mode}});
    println!("{}", serde_json::to_string_pretty(&result)?);
    Ok(())
}
