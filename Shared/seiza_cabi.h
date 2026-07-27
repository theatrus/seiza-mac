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
typedef void (*SeizaCatalogSetupProgressCallback)(const char *, void *);

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
