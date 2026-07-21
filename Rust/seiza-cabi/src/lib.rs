use image::DynamicImage;
use seiza::blind::{BlindIndex, BlindParams, solve_blind};
use seiza::catalog::{StarCatalog, tiles::TileCatalog};
use seiza::objects::{
    GeometryData, GeometryQuality, GeometryRole, ObjectCatalog, ObjectGeometry, ObjectKind,
    ObjectQuery, SkyRegion,
};
use seiza::wcs::Wcs;
use seiza::{DetectBackend, DetectConfig, detect_stars, detect_stars_luma_f32};
use seiza_fits::{FitsImage, HeaderValue, RgbImage16, Statistics, StretchParams};
use serde::Serialize;
use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::path::{Path, PathBuf};
use std::ptr;
use std::time::Instant;

const VERSION: &CStr = c"0.1.0";

#[repr(C)]
pub struct SeizaRenderedImage {
    width: u32,
    height: u32,
    rgba: Vec<u8>,
    metadata_json: CString,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SolveResponse {
    center_ra_degrees: f64,
    center_dec_degrees: f64,
    scale_arcsec_per_pixel: f64,
    matched_stars: usize,
    rms_arcsec: f64,
    detected_stars: usize,
    elapsed_milliseconds: u128,
    detected_star_positions: Vec<ImagePointResponse>,
    catalog_star_positions: Vec<CatalogStarPointResponse>,
    object_positions: Vec<ObjectPointResponse>,
    object_catalog_error: Option<String>,
    wcs: WcsResponse,
}

#[derive(Serialize)]
struct ImagePointResponse {
    x: f64,
    y: f64,
}

#[derive(Serialize)]
struct CatalogStarPointResponse {
    x: f64,
    y: f64,
    magnitude: f32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ObjectPointResponse {
    name: String,
    common_name: String,
    kind: String,
    source: String,
    x: f64,
    y: f64,
    semi_major_pixels: f64,
    semi_minor_pixels: f64,
    angle_degrees: Option<f64>,
    prominence: Option<f64>,
    outlines: Vec<ObjectOutlineResponse>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ObjectOutlineResponse {
    geometry_id: String,
    source_record_id: String,
    role: String,
    quality: String,
    level: Option<String>,
    contours: Vec<ObjectContourResponse>,
}

#[derive(Debug, Serialize)]
struct ObjectContourResponse {
    closed: bool,
    points: Vec<[f64; 2]>,
}

#[derive(Serialize)]
struct WcsResponse {
    crval: [f64; 2],
    crpix: [f64; 2],
    cd: [[f64; 2]; 2],
    sip: Option<SipResponse>,
}

#[derive(Serialize)]
struct SipResponse {
    order: u8,
    a: Vec<f64>,
    b: Vec<f64>,
    ap: Vec<f64>,
    bp: Vec<f64>,
}

#[unsafe(no_mangle)]
pub extern "C" fn seiza_core_version() -> *const c_char {
    VERSION.as_ptr()
}

#[unsafe(no_mangle)]
/// Opens and renders an image for the C ABI.
///
/// # Safety
/// `path` must be a valid NUL-terminated string. When non-null, `error_out`
/// must point to writable storage for one pointer.
pub unsafe extern "C" fn seiza_rendered_image_open(
    path: *const c_char,
    target_median: f64,
    shadows_clip: f64,
    max_dimension: u32,
    error_out: *mut *mut c_char,
) -> *mut SeizaRenderedImage {
    clear_error(error_out);
    ffi_result(error_out, || {
        let path = required_path(path, "image path")?;
        let params = StretchParams {
            target_median: target_median.clamp(0.01, 0.95),
            shadows_clip: shadows_clip.clamp(-10.0, 0.0),
        };
        render_path(&path, &params, max_dimension)
    })
    .map_or(ptr::null_mut(), |image| Box::into_raw(Box::new(image)))
}

#[unsafe(no_mangle)]
/// # Safety
/// `image` must be null or a live pointer returned by
/// [`seiza_rendered_image_open`].
pub unsafe extern "C" fn seiza_rendered_image_width(image: *const SeizaRenderedImage) -> u32 {
    unsafe { image.as_ref().map_or(0, |image| image.width) }
}

#[unsafe(no_mangle)]
/// # Safety
/// `image` must be null or a live pointer returned by
/// [`seiza_rendered_image_open`].
pub unsafe extern "C" fn seiza_rendered_image_height(image: *const SeizaRenderedImage) -> u32 {
    unsafe { image.as_ref().map_or(0, |image| image.height) }
}

#[unsafe(no_mangle)]
/// # Safety
/// `image` must be null or a live pointer returned by
/// [`seiza_rendered_image_open`]. The returned buffer is valid until the image
/// is freed.
pub unsafe extern "C" fn seiza_rendered_image_rgba(image: *const SeizaRenderedImage) -> *const u8 {
    unsafe {
        image
            .as_ref()
            .map_or(ptr::null(), |image| image.rgba.as_ptr())
    }
}

#[unsafe(no_mangle)]
/// # Safety
/// `image` must be null or a live pointer returned by
/// [`seiza_rendered_image_open`].
pub unsafe extern "C" fn seiza_rendered_image_rgba_length(
    image: *const SeizaRenderedImage,
) -> usize {
    unsafe { image.as_ref().map_or(0, |image| image.rgba.len()) }
}

#[unsafe(no_mangle)]
/// # Safety
/// `image` must be null or a live pointer returned by
/// [`seiza_rendered_image_open`]. The returned string is valid until the image
/// is freed.
pub unsafe extern "C" fn seiza_rendered_image_metadata_json(
    image: *const SeizaRenderedImage,
) -> *const c_char {
    unsafe {
        image
            .as_ref()
            .map_or(ptr::null(), |image| image.metadata_json.as_ptr())
    }
}

#[unsafe(no_mangle)]
/// # Safety
/// `image` must be null or a pointer returned by [`seiza_rendered_image_open`]
/// that has not already been freed.
pub unsafe extern "C" fn seiza_rendered_image_free(image: *mut SeizaRenderedImage) {
    if !image.is_null() {
        unsafe { drop(Box::from_raw(image)) };
    }
}

#[unsafe(no_mangle)]
/// Solves an image and returns a JSON string for the C ABI.
///
/// # Safety
/// `path` must be a valid NUL-terminated string. `catalog_directory` may be
/// null or a valid NUL-terminated string. When non-null, `error_out` must point
/// to writable storage for one pointer.
pub unsafe extern "C" fn seiza_solve_image_json(
    path: *const c_char,
    catalog_directory: *const c_char,
    minimum_scale_arcsec_per_pixel: f64,
    maximum_scale_arcsec_per_pixel: f64,
    sip_order: u8,
    error_out: *mut *mut c_char,
) -> *mut c_char {
    clear_error(error_out);
    ffi_result(error_out, || {
        let started = Instant::now();
        let path = required_path(path, "image path")?;
        let catalog_directory = optional_path(catalog_directory)?;
        let detection_config = DetectConfig {
            max_stars: 600,
            ..Default::default()
        };
        let (width, height, mut stars, raster_fallback) = if is_fits_path(&path) {
            let fits = FitsImage::open(&path).map_err(|error| error.to_string())?;
            let width = u32::try_from(fits.width).map_err(|_| "image width is too large")?;
            let height = u32::try_from(fits.height).map_err(|_| "image height is too large")?;
            let luma = fits.to_luma_f32();
            let stars = detect_stars_luma_f32(&luma, width, height, &detection_config);
            (width, height, stars, None)
        } else {
            let image = image::open(&path)
                .map_err(|error| format!("failed to open {}: {error}", path.display()))?;
            let width = image.width();
            let height = image.height();
            let stars = detect_stars(&image, &detection_config);
            let fallback = is_converted_8bit_color(&image).then_some(image);
            (width, height, stars, fallback)
        };

        let star_path = seiza::data_paths::star_data(catalog_directory.as_deref())
            .map_err(|error| error.to_string())?;
        let index_path = seiza::data_paths::blind_index(catalog_directory.as_deref())
            .map_err(|error| error.to_string())?
            .ok_or_else(|| {
                "no blind index found; install a complete Seiza catalog bundle first".to_string()
            })?;
        let catalog = TileCatalog::open(&star_path)
            .map_err(|error| format!("failed to open {}: {error}", star_path.display()))?;
        let index = BlindIndex::open(&index_path)
            .map_err(|error| format!("failed to open {}: {error}", index_path.display()))?;

        let params = BlindParams {
            min_scale_arcsec_px: minimum_scale_arcsec_per_pixel.max(0.01),
            max_scale_arcsec_px: maximum_scale_arcsec_per_pixel
                .max(minimum_scale_arcsec_per_pixel.max(0.01)),
            index_mag_limit: index.index_mag_limit(),
            max_pattern_deg: index.max_pattern_deg(),
            sip_order: sip_order.min(5),
            ..Default::default()
        };
        let solution = match solve_blind(&stars, &catalog, &index, &params, (width, height)) {
            Ok(solution) => solution,
            Err(primary_error) => {
                let Some(image) = raster_fallback else {
                    return Err(primary_error.to_string());
                };
                stars = detect_stars(
                    &image,
                    &DetectConfig {
                        backend: DetectBackend::F32,
                        ..detection_config
                    },
                );
                solve_blind(&stars, &catalog, &index, &params, (width, height))
                    .map_err(|error| error.to_string())?
            }
        };
        let center = solution
            .wcs
            .pixel_to_world(width as f64 / 2.0, height as f64 / 2.0);
        let detected_star_positions = stars
            .iter()
            .take(300)
            .map(|star| ImagePointResponse {
                x: star.x,
                y: star.y,
            })
            .collect();
        let field_radius_degrees =
            (width as f64).hypot(height as f64) / 2.0 * solution.wcs.scale_arcsec_per_px() / 3600.0
                * 1.1;
        let catalog_star_positions = catalog
            .cone_search(center.0, center.1, field_radius_degrees.max(0.05), 1_000)
            .into_iter()
            .filter_map(|star| {
                let (x, y) = solution.wcs.world_to_pixel(star.ra, star.dec)?;
                (x >= 0.0 && y >= 0.0 && x < width as f64 && y < height as f64).then_some(
                    CatalogStarPointResponse {
                        x,
                        y,
                        magnitude: star.mag,
                    },
                )
            })
            .take(300)
            .collect();
        let object_overlay = (|| -> Result<Vec<ObjectPointResponse>, String> {
            let object_path = seiza::data_paths::objects(catalog_directory.as_deref())
                .map_err(|error| error.to_string())?;
            let object_catalog = ObjectCatalog::open(&object_path)
                .map_err(|error| format!("failed to open {}: {error}", object_path.display()))?;
            let prominence_by_id: HashMap<String, f64> = object_catalog
                .query_region(
                    &SkyRegion::Polygon {
                        vertices: solution.wcs.footprint(width, height).to_vec(),
                    },
                    &ObjectQuery::default(),
                )
                .map_err(|error| error.to_string())?
                .into_iter()
                .map(|hit| (hit.object.metadata.id, hit.predicted_prominence))
                .collect();
            let placed = object_catalog
                .objects_in_footprint(&solution.wcs, (width, height))
                .map_err(|error| error.to_string())?;
            Ok(placed
                .into_iter()
                .filter(|placed| {
                    !matches!(
                        placed.object.kind,
                        ObjectKind::Star | ObjectKind::DoubleStar
                    )
                })
                .take(200)
                .map(|placed| {
                    let prominence = prominence_by_id.get(&placed.object.metadata.id).copied();
                    let outlines = projected_outlines(
                        &object_catalog,
                        &placed.object.metadata.id,
                        &solution.wcs,
                    );
                    ObjectPointResponse {
                        name: placed.object.name,
                        common_name: placed.object.common_name,
                        kind: placed.object.kind.as_str().to_string(),
                        source: placed.object.metadata.source,
                        x: placed.x,
                        y: placed.y,
                        semi_major_pixels: placed.semi_major_px,
                        semi_minor_pixels: placed.semi_minor_px,
                        angle_degrees: placed.angle_deg,
                        prominence,
                        outlines,
                    }
                })
                .collect())
        })();
        let (object_positions, object_catalog_error) = match object_overlay {
            Ok(objects) => (objects, None),
            Err(error) => (Vec::new(), Some(error)),
        };
        let sip = solution.wcs.sip.as_ref().map(|sip| SipResponse {
            order: sip.order,
            a: sip.a.clone(),
            b: sip.b.clone(),
            ap: sip.ap.clone(),
            bp: sip.bp.clone(),
        });
        let response = SolveResponse {
            center_ra_degrees: center.0,
            center_dec_degrees: center.1,
            scale_arcsec_per_pixel: solution.wcs.scale_arcsec_per_px(),
            matched_stars: solution.matched_stars,
            rms_arcsec: solution.rms_arcsec,
            detected_stars: stars.len(),
            elapsed_milliseconds: started.elapsed().as_millis(),
            detected_star_positions,
            catalog_star_positions,
            object_positions,
            object_catalog_error,
            wcs: WcsResponse {
                crval: [solution.wcs.crval.0, solution.wcs.crval.1],
                crpix: [solution.wcs.crpix.0, solution.wcs.crpix.1],
                cd: solution.wcs.cd,
                sip,
            },
        };
        let json = serde_json::to_string(&response).map_err(|error| error.to_string())?;
        CString::new(json).map_err(|_| "solution JSON contains a null byte".to_string())
    })
    .map_or(ptr::null_mut(), CString::into_raw)
}

fn projected_outlines(
    catalog: &ObjectCatalog,
    canonical_id: &str,
    wcs: &Wcs,
) -> Vec<ObjectOutlineResponse> {
    let Ok(geometries) = catalog.geometries(canonical_id) else {
        return Vec::new();
    };
    project_outline_geometries(geometries, wcs)
}

fn project_outline_geometries(
    geometries: Vec<ObjectGeometry>,
    wcs: &Wcs,
) -> Vec<ObjectOutlineResponse> {
    geometries
        .into_iter()
        .filter_map(|geometry| {
            let GeometryData::OutlineSet { level, contours } = geometry.data else {
                return None;
            };
            let contours = contours
                .into_iter()
                .filter_map(|contour| {
                    let points = contour
                        .vertices
                        .into_iter()
                        .map(|(ra, dec)| wcs.world_to_pixel(ra, dec).map(|(x, y)| [x, y]))
                        .collect::<Option<Vec<_>>>()?;
                    let minimum_points = if contour.closed { 3 } else { 2 };
                    (points.len() >= minimum_points).then_some(ObjectContourResponse {
                        closed: contour.closed,
                        points,
                    })
                })
                .collect::<Vec<_>>();
            (!contours.is_empty()).then_some(ObjectOutlineResponse {
                geometry_id: geometry.id,
                source_record_id: geometry.source_record_id,
                role: geometry_role_name(geometry.role).into(),
                quality: geometry_quality_name(geometry.quality).into(),
                level,
                contours,
            })
        })
        .collect()
}

fn geometry_role_name(role: GeometryRole) -> &'static str {
    match role {
        GeometryRole::CatalogExtent => "catalog-extent",
        GeometryRole::PreferredRender => "preferred-render",
        GeometryRole::FallbackExtent => "fallback-extent",
        GeometryRole::BrightnessLevel => "brightness-level",
        GeometryRole::Component => "component",
    }
}

fn geometry_quality_name(quality: GeometryQuality) -> &'static str {
    match quality {
        GeometryQuality::Catalog => "catalog",
        GeometryQuality::Curated => "curated",
        GeometryQuality::Estimated => "estimated",
        GeometryQuality::Derived => "derived",
    }
}

#[unsafe(no_mangle)]
/// # Safety
/// `value` must be null or a string returned by this library that has not
/// already been freed.
pub unsafe extern "C" fn seiza_string_free(value: *mut c_char) {
    if !value.is_null() {
        unsafe { drop(CString::from_raw(value)) };
    }
}

fn is_fits_path(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            extension.eq_ignore_ascii_case("fits")
                || extension.eq_ignore_ascii_case("fit")
                || extension.eq_ignore_ascii_case("fts")
        })
}

fn render_path(
    path: &Path,
    params: &StretchParams,
    max_dimension: u32,
) -> Result<SeizaRenderedImage, String> {
    if is_fits_path(path) {
        let fits = FitsImage::open(path).map_err(|error| error.to_string())?;
        render_fits(fits, params, max_dimension)
    } else {
        let image = image::open(path)
            .map_err(|error| format!("failed to open {}: {error}", path.display()))?;
        render_raster(image, raster_format(path), max_dimension)
    }
}

fn render_fits(
    fits: FitsImage,
    params: &StretchParams,
    max_dimension: u32,
) -> Result<SeizaRenderedImage, String> {
    let source_width = fits.width;
    let source_height = fits.height;
    let statistics = fits.statistics();
    let color_kind = if fits.planes == 3 {
        "planar-rgb"
    } else if fits.bayer_pattern().is_some() {
        "bayer"
    } else {
        "mono"
    };

    let rgba = if let Some(rgb) = fits.debayer().or_else(|| fits.rgb_planes()) {
        stretch_rgb(&rgb, params)
    } else {
        let gray = fits.stretch_to_u8(params);
        gray.into_iter()
            .flat_map(|value| [value, value, value, 255])
            .collect()
    };
    let (width, height, rgba) = downsample_rgba(
        source_width,
        source_height,
        rgba,
        usize::try_from(max_dimension).unwrap_or(usize::MAX),
    );

    let mut headers = Map::new();
    for (key, value) in &fits.headers {
        headers.insert(key.clone(), header_json(value));
    }
    let metadata = json!({
        "width": source_width,
        "height": source_height,
        "planes": fits.planes,
        "format": "FITS",
        "colorKind": color_kind,
        "statistics": statistics_json(&statistics),
        "headers": headers,
    });
    let metadata_json = CString::new(metadata.to_string())
        .map_err(|_| "metadata JSON contains a null byte".to_string())?;
    Ok(SeizaRenderedImage {
        width: u32::try_from(width).map_err(|_| "rendered width is too large")?,
        height: u32::try_from(height).map_err(|_| "rendered height is too large")?,
        rgba,
        metadata_json,
    })
}

fn render_raster(
    image: DynamicImage,
    format: &'static str,
    max_dimension: u32,
) -> Result<SeizaRenderedImage, String> {
    let source_width = image.width();
    let source_height = image.height();
    let (planes, color_kind) = raster_encoding(&image);
    let statistics = raster_statistics_json(image.to_luma8().as_raw());
    let rgba = image.to_rgba8().into_raw();
    let (width, height, rgba) = downsample_rgba(
        usize::try_from(source_width).map_err(|_| "image width is too large")?,
        usize::try_from(source_height).map_err(|_| "image height is too large")?,
        rgba,
        usize::try_from(max_dimension).unwrap_or(usize::MAX),
    );
    let metadata = json!({
        "width": source_width,
        "height": source_height,
        "planes": planes,
        "format": format,
        "colorKind": color_kind,
        "statistics": statistics,
        "headers": Map::<String, Value>::new(),
    });
    let metadata_json = CString::new(metadata.to_string())
        .map_err(|_| "metadata JSON contains a null byte".to_string())?;
    Ok(SeizaRenderedImage {
        width: u32::try_from(width).map_err(|_| "rendered width is too large")?,
        height: u32::try_from(height).map_err(|_| "rendered height is too large")?,
        rgba,
        metadata_json,
    })
}

fn raster_format(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|extension| extension.to_str())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("jpg" | "jpeg" | "jfif") => "JPEG",
        Some("png") => "PNG",
        Some("tif" | "tiff") => "TIFF",
        _ => "Raster",
    }
}

fn raster_encoding(image: &DynamicImage) -> (usize, &'static str) {
    match image {
        DynamicImage::ImageLuma8(_) => (1, "mono-8"),
        DynamicImage::ImageLumaA8(_) => (2, "mono-alpha-8"),
        DynamicImage::ImageRgb8(_) => (3, "rgb-8"),
        DynamicImage::ImageRgba8(_) => (4, "rgba-8"),
        DynamicImage::ImageLuma16(_) => (1, "mono-16"),
        DynamicImage::ImageLumaA16(_) => (2, "mono-alpha-16"),
        DynamicImage::ImageRgb16(_) => (3, "rgb-16"),
        DynamicImage::ImageRgba16(_) => (4, "rgba-16"),
        DynamicImage::ImageRgb32F(_) => (3, "rgb-f32"),
        DynamicImage::ImageRgba32F(_) => (4, "rgba-f32"),
        _ => (usize::from(image.color().channel_count()), "raster"),
    }
}

fn is_converted_8bit_color(image: &DynamicImage) -> bool {
    matches!(
        image,
        DynamicImage::ImageLumaA8(_) | DynamicImage::ImageRgb8(_) | DynamicImage::ImageRgba8(_)
    )
}

fn raster_statistics_json(values: &[u8]) -> Value {
    let mut histogram = [0_u64; 256];
    let mut sum = 0_u64;
    for &value in values {
        histogram[usize::from(value)] += 1;
        sum += u64::from(value);
    }
    let count = values.len() as u64;
    let quantile = |histogram: &[u64; 256], rank: u64| -> u8 {
        let mut seen = 0_u64;
        for (value, &frequency) in histogram.iter().enumerate() {
            seen += frequency;
            if seen > rank {
                return value as u8;
            }
        }
        0
    };
    let minimum = histogram
        .iter()
        .position(|&frequency| frequency > 0)
        .unwrap_or(0) as u8;
    let maximum = histogram
        .iter()
        .rposition(|&frequency| frequency > 0)
        .unwrap_or(0) as u8;
    let median = quantile(&histogram, count.saturating_sub(1) / 2);
    let mut deviation_histogram = [0_u64; 256];
    for (value, &frequency) in histogram.iter().enumerate() {
        deviation_histogram[value.abs_diff(usize::from(median))] += frequency;
    }
    let mad = quantile(&deviation_histogram, count.saturating_sub(1) / 2);
    json!({
        "minimum": minimum,
        "maximum": maximum,
        "mean": if count == 0 { 0.0 } else { sum as f64 / count as f64 },
        "median": median,
        "mad": mad,
    })
}

fn stretch_rgb(rgb: &RgbImage16, params: &StretchParams) -> Vec<u8> {
    let mut channels = [Vec::new(), Vec::new(), Vec::new()];
    for pixel in rgb.data.chunks_exact(3) {
        channels[0].push(pixel[0]);
        channels[1].push(pixel[1]);
        channels[2].push(pixel[2]);
    }
    let stretched = channels.map(|channel| {
        let statistics = seiza_fits::statistics_u16(&channel);
        seiza_fits::stretch_u16_to_u8(&channel, &statistics, params)
    });
    (0..rgb.width * rgb.height)
        .flat_map(|index| {
            [
                stretched[0][index],
                stretched[1][index],
                stretched[2][index],
                255,
            ]
        })
        .collect()
}

fn downsample_rgba(
    width: usize,
    height: usize,
    rgba: Vec<u8>,
    max_dimension: usize,
) -> (usize, usize, Vec<u8>) {
    if max_dimension == 0 || width.max(height) <= max_dimension {
        return (width, height, rgba);
    }
    let scale = max_dimension as f64 / width.max(height) as f64;
    let output_width = ((width as f64 * scale).round() as usize).max(1);
    let output_height = ((height as f64 * scale).round() as usize).max(1);
    let mut output = Vec::with_capacity(output_width * output_height * 4);
    for y in 0..output_height {
        let source_y = y * height / output_height;
        for x in 0..output_width {
            let source_x = x * width / output_width;
            let offset = (source_y * width + source_x) * 4;
            output.extend_from_slice(&rgba[offset..offset + 4]);
        }
    }
    (output_width, output_height, output)
}

fn header_json(value: &HeaderValue) -> Value {
    match value {
        HeaderValue::Integer(value) => json!(value),
        HeaderValue::Float(value) if value.is_finite() => json!(value),
        HeaderValue::Float(value) => json!(value.to_string()),
        HeaderValue::String(value) => json!(value),
        HeaderValue::Logical(value) => json!(value),
        HeaderValue::Raw(value) => json!(value),
    }
}

fn statistics_json(statistics: &Statistics) -> Value {
    json!({
        "minimum": statistics.min,
        "maximum": statistics.max,
        "mean": statistics.mean,
        "median": statistics.median,
        "mad": statistics.mad,
    })
}

fn required_path(value: *const c_char, name: &str) -> Result<PathBuf, String> {
    optional_path(value)?.ok_or_else(|| format!("{name} is required"))
}

fn optional_path(value: *const c_char) -> Result<Option<PathBuf>, String> {
    if value.is_null() {
        return Ok(None);
    }
    let value = unsafe { CStr::from_ptr(value) }
        .to_str()
        .map_err(|_| "path is not valid UTF-8".to_string())?;
    if value.is_empty() {
        Ok(None)
    } else {
        Ok(Some(Path::new(value).to_path_buf()))
    }
}

fn ffi_result<T>(
    error_out: *mut *mut c_char,
    body: impl FnOnce() -> Result<T, String>,
) -> Option<T> {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(value)) => Some(value),
        Ok(Err(error)) => {
            set_error(error_out, error);
            None
        }
        Err(_) => {
            set_error(error_out, "Seiza core panicked".to_string());
            None
        }
    }
}

fn clear_error(error_out: *mut *mut c_char) {
    if !error_out.is_null() {
        unsafe { *error_out = ptr::null_mut() };
    }
}

fn set_error(error_out: *mut *mut c_char, error: String) {
    if error_out.is_null() {
        return;
    }
    let sanitized = error.replace('\0', "�");
    if let Ok(error) = CString::new(sanitized) {
        unsafe { *error_out = error.into_raw() };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn card(value: &str) -> [u8; 80] {
        let mut card = [b' '; 80];
        card[..value.len()].copy_from_slice(value.as_bytes());
        card
    }

    fn synthetic_fits() -> Vec<u8> {
        let mut bytes = Vec::new();
        for value in [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "NAXIS1  =                    2",
            "NAXIS2  =                    2",
            "BZERO   =                32768",
            "OBJECT  = 'M42'",
            "END",
        ] {
            bytes.extend_from_slice(&card(value));
        }
        bytes.resize(2880, b' ');
        for value in [0_i16, 100, 1000, 20_000] {
            bytes.write_all(&value.to_be_bytes()).unwrap();
        }
        bytes.resize(5760, 0);
        bytes
    }

    #[test]
    fn renders_a_synthetic_fits_and_reports_metadata() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("test.fits");
        std::fs::write(&path, synthetic_fits()).unwrap();

        let image = render_fits(
            FitsImage::open(&path).unwrap(),
            &StretchParams::default(),
            0,
        )
        .unwrap();
        assert_eq!((image.width, image.height), (2, 2));
        assert_eq!(image.rgba.len(), 16);
        let metadata: Value = serde_json::from_str(image.metadata_json.to_str().unwrap()).unwrap();
        assert_eq!(metadata["headers"]["OBJECT"], "M42");
        assert_eq!(metadata["format"], "FITS");
        assert_eq!(metadata["colorKind"], "mono");
    }

    #[test]
    fn renders_a_png_and_reports_raster_metadata() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("test.png");
        let source = image::RgbImage::from_fn(3, 2, |x, y| {
            image::Rgb([(x * 70) as u8, (y * 90) as u8, 150])
        });
        source.save(&path).unwrap();

        let image = render_path(&path, &StretchParams::default(), 0).unwrap();
        assert_eq!((image.width, image.height), (3, 2));
        assert_eq!(image.rgba.len(), 24);
        let metadata: Value = serde_json::from_str(image.metadata_json.to_str().unwrap()).unwrap();
        assert_eq!(metadata["format"], "PNG");
        assert_eq!(metadata["colorKind"], "rgb-8");
        assert_eq!(metadata["headers"], json!({}));
    }

    #[test]
    fn downsampling_preserves_aspect_ratio() {
        let rgba = vec![255; 400 * 200 * 4];
        let (width, height, pixels) = downsample_rgba(400, 200, rgba, 100);
        assert_eq!((width, height), (100, 50));
        assert_eq!(pixels.len(), 100 * 50 * 4);
    }

    #[test]
    fn projects_catalog_outline_geometry_into_image_pixels() {
        let wcs = Wcs::from_center_scale_rotation((10.0, 20.0), (100.0, 100.0), 3.6, 0.0, false);
        let expected = [(30.0, 40.0), (70.0, 40.0), (50.0, 80.0)];
        let vertices = expected
            .iter()
            .map(|&(x, y)| wcs.pixel_to_world(x, y))
            .collect();
        let outlines = project_outline_geometries(
            vec![ObjectGeometry {
                id: "openngc:NGC1#outline-1".into(),
                source_record_id: "openngc:NGC1".into(),
                role: GeometryRole::BrightnessLevel,
                quality: GeometryQuality::Catalog,
                method: "OpenNGC outline".into(),
                evidence: String::new(),
                data: GeometryData::OutlineSet {
                    level: Some("1".into()),
                    contours: vec![seiza::objects::ObjectContour {
                        closed: true,
                        vertices,
                    }],
                },
            }],
            &wcs,
        );

        assert_eq!(outlines.len(), 1);
        assert_eq!(outlines[0].role, "brightness-level");
        assert_eq!(outlines[0].quality, "catalog");
        assert_eq!(outlines[0].level.as_deref(), Some("1"));
        assert!(outlines[0].contours[0].closed);
        for (actual, expected) in outlines[0].contours[0].points.iter().zip(expected) {
            assert!((actual[0] - expected.0).abs() < 1e-6);
            assert!((actual[1] - expected.1).abs() < 1e-6);
        }
    }
}
