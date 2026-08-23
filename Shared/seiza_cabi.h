#ifndef SEIZA_CABI_H
#define SEIZA_CABI_H

/* Client declarations for the upstream seiza-cabi crate linked by seiza-mac. */

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct SeizaRenderedImage SeizaRenderedImage;
typedef struct SeizaRenderedImage16 SeizaRenderedImage16;
typedef struct SeizaLiveStacker SeizaLiveStacker;
typedef struct SeizaStackSnapshot SeizaStackSnapshot;
typedef struct SeizaStackExportSnapshot SeizaStackExportSnapshot;
typedef struct SeizaCancelSignal SeizaCancelSignal;
typedef void (*SeizaCatalogSetupProgressCallback)(const char *, void *);

#define SEIZA_SNR_MAX_CHANNELS 3

#define SEIZA_FRAME_HAS_WIDTH (1 << 0)
#define SEIZA_FRAME_HAS_HEIGHT (1 << 1)
#define SEIZA_FRAME_HAS_CHANNELS (1 << 2)
#define SEIZA_FRAME_HAS_BINNING_X (1 << 3)
#define SEIZA_FRAME_HAS_BINNING_Y (1 << 4)
#define SEIZA_FRAME_HAS_GAIN (1 << 5)
#define SEIZA_FRAME_HAS_OFFSET (1 << 6)
#define SEIZA_FRAME_HAS_READOUT_MODE (1 << 7)
#define SEIZA_FRAME_HAS_FOCAL_LENGTH (1 << 8)
#define SEIZA_FRAME_HAS_ROTATION (1 << 9)
#define SEIZA_FRAME_HAS_EXPOSURE (1 << 10)
#define SEIZA_FRAME_HAS_CAMERA_TEMP (1 << 11)
#define SEIZA_FRAME_HAS_CAPTURED_AT (1 << 12)

#define SEIZA_TOLERANCE_HAS_EXPOSURE (1 << 0)
#define SEIZA_TOLERANCE_HAS_DARK_TEMPERATURE (1 << 1)
#define SEIZA_TOLERANCE_HAS_MASTER_TEMPERATURE (1 << 2)
#define SEIZA_TOLERANCE_HAS_ROTATION (1 << 3)
#define SEIZA_TOLERANCE_HAS_FOCAL_LENGTH (1 << 4)
#define SEIZA_TOLERANCE_HAS_FLAT_SESSION (1 << 5)
#define SEIZA_TOLERANCE_HAS_EXPOSURE_FRACTION (1 << 6)

/* A cleared `SEIZA_FRAME_HAS_*` bit means the numeric field was not
   recorded; a zeroed struct means nothing recorded. Text fields need no
   flag; null means unknown. */
typedef struct {
  uint32_t known;
  const char *camera;
  const char *telescope;
  const char *bayer_pattern;
  const char *filter;
  double width;
  double height;
  double channels;
  double binning_x;
  double binning_y;
  double gain;
  double offset;
  double readout_mode;
  double focal_length_mm;
  double rotation_deg;
  double exposure_seconds;
  double camera_temp_c;
  double captured_at_unix;
} SeizaFrameSignature;

/* A cleared `SEIZA_TOLERANCE_HAS_*` bit takes the native default; a
   zeroed struct or a null pointer means all defaults. */
typedef struct {
  uint32_t known;
  double exposure_seconds;
  double exposure_fraction;
  double dark_temperature_c;
  double master_temperature_c;
  double rotation_deg;
  double focal_length_mm;
  uint64_t flat_session_seconds;
} SeizaMatchTolerances;

/* One reading of an accumulator, in the stack's own units. `sample` is
   written only when the measuring call returns exactly 1. */
typedef struct {
  uint32_t frames;
  double noise;
  double background;
  double signal;
  double snr;
  size_t channel_count;
  double channel_noise[SEIZA_SNR_MAX_CHANNELS];
} SeizaSnrSample;

#ifdef __cplusplus
extern "C" {
#endif

const char *seiza_core_version(void);

char *seiza_catalog_status_json(
    const char *catalog_directory,
    char **error_out);

bool seiza_catalog_setup(
    const char *catalog_directory,
    uint32_t preset,
    SeizaCatalogSetupProgressCallback progress,
    void *context,
    char **error_out);

SeizaRenderedImage *seiza_rendered_image_open(
    const char *path,
    double target_median,
    double shadows_clip,
    uint32_t max_dimension,
    char **error_out);

SeizaRenderedImage *seiza_rendered_image_open_with_rgb_stretch(
    const char *path,
    double target_median,
    double shadows_clip,
    uint32_t max_dimension,
    uint32_t rgb_stretch_mode,
    char **error_out);

SeizaRenderedImage *seiza_rendered_image_open_with_stretch_config(
    const char *path,
    const char *config_json,
    uint32_t max_dimension,
    char **error_out);

SeizaRenderedImage16 *seiza_rendered_image16_open(
    const char *path,
    double target_median,
    double shadows_clip,
    uint32_t max_dimension,
    char **error_out);

SeizaRenderedImage16 *seiza_rendered_image16_open_with_rgb_stretch(
    const char *path,
    double target_median,
    double shadows_clip,
    uint32_t max_dimension,
    uint32_t rgb_stretch_mode,
    char **error_out);

SeizaRenderedImage16 *seiza_rendered_image16_open_with_stretch_config(
    const char *path,
    const char *config_json,
    uint32_t max_dimension,
    char **error_out);

uint32_t seiza_rendered_image_width(const SeizaRenderedImage *image);
uint32_t seiza_rendered_image_height(const SeizaRenderedImage *image);
const uint8_t *seiza_rendered_image_rgba(const SeizaRenderedImage *image);
size_t seiza_rendered_image_rgba_length(const SeizaRenderedImage *image);
const uint8_t *seiza_rendered_image_bgra(const SeizaRenderedImage *image);
size_t seiza_rendered_image_bgra_length(const SeizaRenderedImage *image);
const char *seiza_rendered_image_metadata_json(const SeizaRenderedImage *image);
void seiza_rendered_image_free(SeizaRenderedImage *image);

uint32_t seiza_rendered_image16_width(const SeizaRenderedImage16 *image);
uint32_t seiza_rendered_image16_height(const SeizaRenderedImage16 *image);
const uint16_t *seiza_rendered_image16_rgba(const SeizaRenderedImage16 *image);
size_t seiza_rendered_image16_rgba_length(const SeizaRenderedImage16 *image);
const char *seiza_rendered_image16_metadata_json(const SeizaRenderedImage16 *image);
void seiza_rendered_image16_free(SeizaRenderedImage16 *image);

SeizaLiveStacker *seiza_live_stacker_open_fits(
    const char *reference_path,
    const char *bias_path,
    const char *dark_path,
    const char *flat_path,
    double dark_exposure_seconds,
    const char *options_json,
    char **error_out);

char *seiza_live_stacker_push_fits_json(
    SeizaLiveStacker *stacker,
    const char *path,
    char **error_out);

SeizaLiveStacker *seiza_live_stacker_open_context(
    const char *context_path,
    char **error_out);

bool seiza_live_stacker_save_context(
    const SeizaLiveStacker *stacker,
    const char *context_path,
    char **error_out);

char *seiza_live_stacker_state_json(
    const SeizaLiveStacker *stacker,
    char **error_out);

bool seiza_live_stacker_set_calibration_fits(
    SeizaLiveStacker *stacker,
    const char *bias_path,
    const char *dark_path,
    const char *flat_path,
    double dark_exposure_seconds,
    char **error_out);

char *seiza_live_stacker_compatible_calibration_json(
    const SeizaLiveStacker *stacker,
    const SeizaFrameSignature *signature,
    const SeizaMatchTolerances *tolerances,
    char **error_out);

SeizaRenderedImage *seiza_live_stacker_render_preview(
    const SeizaLiveStacker *stacker,
    const char *config_json,
    uint32_t max_dimension,
    char **error_out);

SeizaStackExportSnapshot *seiza_live_stacker_export_snapshot(
    const SeizaLiveStacker *stacker,
    char **error_out);

/* Returns 1 when a sample was written, 0 when no reading is available
   (an error only when error_out was set), negative on failure. Test the
   return against 1, not for truth. */
int32_t seiza_live_stacker_measure_depth(
    const SeizaLiveStacker *stacker,
    SeizaSnrSample *sample,
    char **error_out);

uint32_t seiza_live_stacker_accepted_frames(const SeizaLiveStacker *stacker);
uint32_t seiza_live_stacker_rejected_frames(const SeizaLiveStacker *stacker);
SeizaStackSnapshot *seiza_live_stacker_finish(
    SeizaLiveStacker **stacker,
    char **error_out);
void seiza_live_stacker_free(SeizaLiveStacker *stacker);

uint32_t seiza_stack_snapshot_accepted_frames(const SeizaStackSnapshot *snapshot);
uint32_t seiza_stack_snapshot_rejected_frames(const SeizaStackSnapshot *snapshot);
bool seiza_stack_snapshot_write_fits(
    const SeizaStackSnapshot *snapshot,
    const char *path,
    char **error_out);
void seiza_stack_snapshot_free(SeizaStackSnapshot *snapshot);

bool seiza_stack_export_snapshot_write_fits(
    const SeizaStackExportSnapshot *snapshot,
    const char *path,
    char **error_out);
void seiza_stack_export_snapshot_free(SeizaStackExportSnapshot *snapshot);

SeizaCancelSignal *seiza_cancel_signal_create(void);
void seiza_cancel_signal_cancel(const SeizaCancelSignal *signal);
void seiza_cancel_signal_free(SeizaCancelSignal *signal);

char *seiza_probe_frame_json(const char *path, char **error_out);
char *seiza_calibration_plan_json(const char *request_json, char **error_out);
char *seiza_calibration_build_master_json(
    const char *request_json,
    const SeizaCancelSignal *cancel,
    char **error_out);

void seiza_frame_signature_init(SeizaFrameSignature *signature);
void seiza_match_tolerances_default(SeizaMatchTolerances *tolerances);

/* Matchers return 1 = match, 0 = no match, negative = failure with
   error_out set. Test against 1, not for truth. */
int32_t seiza_calibration_sensor_matches(
    const SeizaFrameSignature *reference,
    const SeizaFrameSignature *candidate,
    char **error_out);
int32_t seiza_calibration_optics_match(
    const SeizaFrameSignature *reference,
    const SeizaFrameSignature *candidate,
    const SeizaMatchTolerances *tolerances,
    char **error_out);
int32_t seiza_calibration_dark_matches(
    const SeizaFrameSignature *reference,
    const SeizaFrameSignature *candidate,
    const SeizaMatchTolerances *tolerances,
    char **error_out);
int32_t seiza_calibration_rotation_matches(
    double reference_deg,
    double candidate_deg,
    double tolerance_deg);

char *seiza_calibration_describe_sensor_mismatch(
    const SeizaFrameSignature *reference,
    const SeizaFrameSignature *candidate,
    char **error_out);
char *seiza_calibration_describe_optics_mismatch(
    const SeizaFrameSignature *reference,
    const SeizaFrameSignature *candidate,
    const SeizaMatchTolerances *tolerances,
    char **error_out);

size_t seiza_checkpoint_depths(size_t total, size_t *out, size_t out_len);

char *seiza_solve_image_json(
    const char *path,
    const char *catalog_directory,
    double minimum_scale_arcsec_per_pixel,
    double maximum_scale_arcsec_per_pixel,
    uint8_t sip_order,
    char **error_out);

void seiza_string_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
