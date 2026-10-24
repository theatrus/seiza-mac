//! Mac-only adapter for a focused parallax download. The upstream C preset
//! currently offers distances only as part of Everything; transfer, cache,
//! hashing and atomic installation still come from seiza-download.
use seiza::catalog::{ObjectDistances, StarDistanceCatalog};
use seiza_download::{CachePolicy, CatalogManager, CatalogSet, Dataset, DownloadEvent};
use serde_json::{Value, json};
use std::ffi::{CStr, CString, c_char, c_void};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

type Progress = Option<unsafe extern "C" fn(*const c_char, *mut c_void)>;

fn selection() -> CatalogSet {
    CatalogSet::star_distances()
        .with(Dataset::ObjectDistances)
        .with(Dataset::Objects)
}

unsafe fn directory(pointer: *const c_char) -> Result<PathBuf, String> {
    if pointer.is_null() {
        return Ok(seiza::data_paths::default_catalog_dir());
    }
    let value = unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|error| error.to_string())?;
    if value.is_empty() {
        return Err("The catalogue directory must not be empty".into());
    }
    Ok(PathBuf::from(value))
}

fn status(directory: &Path) -> Value {
    let component = |name: &str, result: Result<Value, String>| {
        let path = directory.join(name);
        match result {
            Ok(mut value) => {
                value["available"] = true.into();
                value["path"] = path.to_string_lossy().as_ref().into();
                value
            }
            Err(error) => json!({"available": false, "path": path,
                "error": if path.exists() { Some(error) } else { None }}),
        }
    };
    let stars = StarDistanceCatalog::open(&directory.join("star-distances.bin"))
        .map(
            |catalog| json!({"maxMagnitude": catalog.max_mag(), "starCount": catalog.star_count()}),
        )
        .map_err(|error| error.to_string());
    let objects = ObjectDistances::open_unpaired(&directory.join("object-distances.bin"))
        .map(|_| json!({}))
        .map_err(|error| error.to_string());
    json!({"directory": directory, "stars": component("star-distances.bin", stars),
        "objects": component("object-distances.bin", objects)})
}

fn progress_json(event: DownloadEvent, completed: usize) -> Value {
    let (phase, message, name, bytes) = match event {
        DownloadEvent::FetchingManifest { .. } => (
            "manifest",
            "Checking the mirror for offline distances…".into(),
            None,
            None,
        ),
        DownloadEvent::UsingCachedManifest { version, .. } => (
            "manifest",
            format!("Using catalogue manifest {version}"),
            None,
            None,
        ),
        DownloadEvent::CacheHit { name, .. } => (
            "preparing",
            format!("Using cached {name}"),
            Some(name),
            None,
        ),
        DownloadEvent::DownloadStarted { name, bytes } => (
            "downloading",
            format!("Downloading {name}"),
            Some(name),
            Some((0, bytes, 0)),
        ),
        DownloadEvent::DownloadProgress {
            name,
            downloaded,
            total,
            written,
        } => (
            "downloading",
            format!("Downloading {name}"),
            Some(name),
            Some((downloaded, total, written)),
        ),
        DownloadEvent::DownloadComplete { name, .. } => {
            ("preparing", format!("Downloaded {name}"), Some(name), None)
        }
        DownloadEvent::Verifying { name } => (
            "verifying",
            format!("Verifying SHA-256 for {name}"),
            Some(name),
            None,
        ),
        DownloadEvent::Installing { name, .. } => {
            ("installing", format!("Installing {name}"), Some(name), None)
        }
        DownloadEvent::InstallComplete { name, .. } => {
            ("installing", format!("Installed {name}"), Some(name), None)
        }
    };
    json!({"phase": phase, "message": message, "fileName": name,
        "filesCompleted": completed, "filesTotal": 3,
        "bytesCompleted": bytes.map(|b| b.0), "bytesTotal": bytes.map(|b| b.1), "writtenBytes": bytes.map(|b| b.2)})
}

fn send(callback: Progress, context: usize, value: Value) {
    if let Some(callback) = callback {
        let text = CString::new(value.to_string()).expect("JSON escapes NULs");
        unsafe { callback(text.as_ptr(), context as *mut c_void) };
    }
}

fn download_error(error: seiza_download::Error) -> String {
    if let seiza_download::Error::Manifest(message) = &error
        && let Some(missing) = message.strip_prefix("requested file(s) unavailable: ")
        && missing
            .split(';')
            .next()
            .is_some_and(|names| names.contains("star-distances.bin"))
    {
        return "The stellar distance database is not published on the Seiza mirror yet. Try Download Offline Distances again after the upload finishes.".into();
    }
    error.to_string()
}

fn install(directory: &Path, callback: Progress, context: usize) -> Result<(), String> {
    let manager = CatalogManager::builder()
        .policy(CachePolicy::ForceRefresh)
        .build()
        .map_err(|e| e.to_string())?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    runtime.block_on(async {
        let bundle = manager
            .ensure_with(&selection(), |event| {
                send(callback, context, progress_json(event, 0))
            })
            .await
            .map_err(download_error)?;
        // Explicit verification also re-hashes existing cached artifacts.
        bundle
            .verify_with(|event| send(callback, context, progress_json(event, 0)))
            .await
            .map_err(|error| error.to_string())?;
        let completed = AtomicUsize::new(0);
        bundle
            .materialize_with(directory, |event| {
                if matches!(event, DownloadEvent::InstallComplete { .. }) {
                    completed.fetch_add(1, Ordering::Relaxed);
                }
                send(
                    callback,
                    context,
                    progress_json(event, completed.load(Ordering::Relaxed)),
                );
            })
            .await
            .map_err(|error| error.to_string())?;
        Ok::<_, String>(())
    })?;
    send(
        callback,
        context,
        json!({"phase": "complete", "message": "Offline parallax catalogues installed and verified.", "filesCompleted": 3, "filesTotal": 3}),
    );
    Ok(())
}

pub(crate) fn boundary<T>(
    error_out: *mut *mut c_char,
    operation: impl FnOnce() -> Result<T, String>,
) -> Option<T> {
    if !error_out.is_null() {
        unsafe { *error_out = std::ptr::null_mut() };
    }
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(operation))
        .unwrap_or_else(|_| Err("Catalogue operation failed unexpectedly".into()));
    match result {
        Ok(value) => Some(value),
        Err(error) => {
            if !error_out.is_null() {
                let text = CString::new(error.replace('\0', " ")).expect("NULs removed");
                unsafe { *error_out = text.into_raw() };
            }
            None
        }
    }
}

/// Validate local distance databases without scanning every record.
/// Returned JSON/error strings are released with seiza_string_free.
/// # Safety
/// Directory is null or a NUL-terminated UTF-8 path. error_out is null or writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn seiza_mac_distance_catalog_status_json(
    directory_pointer: *const c_char,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    boundary(error_out, || {
        let directory = unsafe { directory(directory_pointer) }?;
        Ok(CString::new(status(&directory).to_string())
            .expect("JSON escapes NULs")
            .into_raw())
    })
    .unwrap_or(std::ptr::null_mut())
}

/// Install only stellar distances, object distances, and the object catalogue.
/// Synchronous: run on a worker thread outside any Tokio runtime. Callback JSON
/// is borrowed for the callback duration. Failed setup is safe to retry.
/// # Safety
/// Directory is null or a NUL-terminated UTF-8 path; error_out is null or writable.
/// Callback/context must remain valid until this call returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn seiza_mac_catalog_setup_parallax(
    directory_pointer: *const c_char,
    callback: Progress,
    context: *mut c_void,
    error_out: *mut *mut c_char,
) -> bool {
    boundary(error_out, || {
        let directory = unsafe { directory(directory_pointer) }?;
        install(&directory, callback, context as usize)
    })
    .is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parallax_selection_and_compressed_progress_are_precise() {
        let hash = "a".repeat(64);
        let files: Vec<_> = seiza_download::REQUIRED_BUNDLE_FILES
            .iter()
            .copied()
            .chain([
                "star-distances.bin",
                "object-distances.bin",
                "stars-deep-gaia20.bin",
            ])
            .map(|name| {
                json!({"name": name, "bytes": 1, "sha256": hash,
                "key": format!("artifacts/{hash}/{name}")})
            })
            .collect();
        let document = json!({"version": "catalog-bundle-v4-test", "files": files});
        let manifest =
            seiza_download::BundleManifest::parse(&serde_json::to_vec(&document).unwrap()).unwrap();
        let files = manifest.plan(&selection()).unwrap();
        assert_eq!(files.len(), 3);
        let mut unpublished = manifest.clone();
        unpublished
            .files
            .retain(|file| file.name != "star-distances.bin");
        let error = unpublished.plan(&selection()).unwrap_err();
        assert!(download_error(error).contains("not published on the Seiza mirror yet"));
        let event = progress_json(
            DownloadEvent::DownloadProgress {
                name: "star-distances.bin".into(),
                downloaded: 20,
                total: 100,
                written: 60,
            },
            0,
        );
        assert_eq!(event["bytesCompleted"], 20);
        assert_eq!(event["writtenBytes"], 60);
        assert_eq!(event["filesTotal"], 3);
    }
    #[test]
    fn status_rejects_corruption_and_reads_star_depth() {
        let temp = tempfile::tempdir().unwrap();
        assert_eq!(status(temp.path())["stars"]["available"], false);
        std::fs::write(temp.path().join("star-distances.bin"), b"bad").unwrap();
        assert!(status(temp.path())["stars"]["error"].is_string());
        seiza::catalog::StarDistanceCatalogBuilder::new(16, 2016.0, 17.0, "test")
            .write_to(&temp.path().join("star-distances.bin"))
            .unwrap();
        let result = status(temp.path());
        assert_eq!(result["stars"]["available"], true);
        assert_eq!(result["stars"]["maxMagnitude"], 17.0);
        assert_eq!(result["objects"]["available"], false);
    }
}
