// Compatibility adapter for C ABI 0.32.0. Remove when adopting seiza #277:
// native reads, replacements and exports then all use full-source coordinates.
// See docs/PARALLAX-VIDEO.md's release gate before changing the core pins.
use seiza_parallax::{Dust, DustMap};
use serde::Deserialize;
use std::ffi::{CStr, CString, c_char};
use std::path::PathBuf;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    path: PathBuf,
    output: PathBuf,
    source_width: usize,
    source_height: usize,
    crop: [usize; 4],
    expand: bool,
    base: Option<PathBuf>,
}

fn resized(map: &DustMap, width: usize, height: usize) -> Result<DustMap, String> {
    Dust::from_map(map, width, height)?; // Validate values and source aspect.
    if (map.width, map.height) == (width, height) {
        return Ok(DustMap {
            width,
            height,
            opacity: map.opacity.clone(),
        });
    }
    let mut opacity = Vec::with_capacity(width.checked_mul(height).ok_or("The map is too large")?);
    for y in 0..height {
        let fy = ((y as f64 + 0.5) * map.height as f64 / height as f64 - 0.5)
            .clamp(0.0, (map.height - 1) as f64);
        let y0 = fy.floor() as usize;
        let y1 = (y0 + 1).min(map.height - 1);
        let ty = (fy - y0 as f64) as f32;
        for x in 0..width {
            let fx = ((x as f64 + 0.5) * map.width as f64 / width as f64 - 0.5)
                .clamp(0.0, (map.width - 1) as f64);
            let x0 = fx.floor() as usize;
            let x1 = (x0 + 1).min(map.width - 1);
            let tx = (fx - x0 as f64) as f32;
            let top = map.opacity[y0 * map.width + x0] * (1.0 - tx)
                + map.opacity[y0 * map.width + x1] * tx;
            let bottom = map.opacity[y1 * map.width + x0] * (1.0 - tx)
                + map.opacity[y1 * map.width + x1] * tx;
            opacity.push(top * (1.0 - ty) + bottom * ty);
        }
    }
    Ok(DustMap {
        width,
        height,
        opacity,
    })
}

fn transform(map: &DustMap, request: &Request) -> Result<DustMap, String> {
    let [x, y, width, height] = request.crop;
    let (sw, sh) = (request.source_width, request.source_height);
    if width < 16
        || height < 16
        || x.checked_add(width).is_none_or(|end| end > sw)
        || y.checked_add(height).is_none_or(|end| end > sh)
    {
        return Err("The dust-map crop must lie inside the source image".into());
    }
    if request.expand {
        let length = sw.checked_mul(sh).ok_or("The source map is too large")?;
        let mut opacity = if let Some(path) = &request.base {
            resized(&DustMap::open(path)?, sw, sh)?.opacity
        } else {
            vec![0.0; length]
        };
        let cropped = resized(map, width, height)?;
        for row in 0..height {
            opacity[(y + row) * sw + x..(y + row) * sw + x + width]
                .copy_from_slice(&cropped.opacity[row * width..(row + 1) * width]);
        }
        Ok(DustMap {
            width: sw,
            height: sh,
            opacity,
        })
    } else {
        // Validate the source aspect, then use the same rounded grid corners
        // as upstream crop_inputs, preserving a lower-resolution painted map.
        Dust::from_map(map, sw, sh)?;
        let along = |at: usize, source: usize, grid: usize| {
            ((at as f64 * grid as f64 / source as f64).round() as usize).min(grid)
        };
        let (x0, y0) = (along(x, sw, map.width), along(y, sh, map.height));
        let x1 = along(x + width, sw, map.width).max(x0 + 1).min(map.width);
        let y1 = along(y + height, sh, map.height)
            .max(y0 + 1)
            .min(map.height);
        let (x0, y0) = (x0.min(x1 - 1), y0.min(y1 - 1));
        let opacity = (y0..y1)
            .flat_map(|row| {
                map.opacity[row * map.width + x0..row * map.width + x1]
                    .iter()
                    .copied()
            })
            .collect();
        Ok(DustMap {
            width: x1 - x0,
            height: y1 - y0,
            opacity,
        })
    }
}

/// Translate painted dust maps between source and cropped-scene geometry.
///
/// # Safety
/// `request` must be a NUL-terminated UTF-8 JSON string. `error_out` must be
/// null or writable pointer storage. Free any returned error with seiza_string_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn seiza_mac_dust_map_transform_json(
    request: *const c_char,
    error_out: *mut *mut c_char,
) -> bool {
    if !error_out.is_null() {
        unsafe {
            *error_out = std::ptr::null_mut();
        }
    }
    let result = std::panic::catch_unwind(|| -> Result<(), String> {
        if request.is_null() {
            return Err("Dust-map request is null".into());
        }
        let json = unsafe { CStr::from_ptr(request) }
            .to_str()
            .map_err(|error| error.to_string())?;
        let request: Request = serde_json::from_str(json).map_err(|error| error.to_string())?;
        let map = DustMap::open(&request.path)?;
        transform(&map, &request)?.save(&request.output)
    })
    .unwrap_or_else(|_| Err("Dust-map conversion failed".into()));
    match result {
        Ok(()) => true,
        Err(error) => {
            if !error_out.is_null() {
                let message = CString::new(error.replace('\0', " ")).expect("NULs replaced");
                unsafe {
                    *error_out = message.into_raw();
                }
            }
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crop_and_expand_keep_source_positions_and_outside_pixels_clear() {
        let map = DustMap {
            width: 64,
            height: 48,
            opacity: (0..64 * 48)
                .map(|i| {
                    if i % 64 >= 20 && i / 64 >= 12 {
                        1.0
                    } else {
                        0.0
                    }
                })
                .collect(),
        };
        let mut request = Request {
            path: PathBuf::new(),
            output: PathBuf::new(),
            source_width: 64,
            source_height: 48,
            crop: [16, 8, 32, 24],
            expand: false,
            base: None,
        };
        let cropped = transform(&map, &request).unwrap();
        assert_eq!((cropped.width, cropped.height), (32, 24));
        assert_eq!(cropped.opacity[4 * 32 + 4], 1.0);
        assert_eq!(cropped.opacity[0], 0.0);
        request.expand = true;
        let expanded = transform(&cropped, &request).unwrap();
        assert_eq!((expanded.width, expanded.height), (64, 48));
        assert_eq!(expanded.opacity[12 * 64 + 20], 1.0);
        assert_eq!(expanded.opacity[40 * 64 + 60], 0.0);
        request.crop = [usize::MAX, 0, 32, 24];
        assert!(transform(&map, &request).is_err());
    }
}
