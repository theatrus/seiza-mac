#include "seiza_cabi.h"

const char *seiza_mac_core_git_commit(void);
const char *seiza_mac_core_package_version(void);
const char *seiza_mac_core_package_checksum(void);
const char *seiza_mac_core_package_source(void);

// Mac adapters; keep the vendored upstream header unchanged.
char *seiza_mac_distance_catalog_status_json(const char *directory, char **error_out);
bool seiza_mac_catalog_setup_parallax(const char *directory,
    SeizaCatalogSetupProgressCallback progress, void *context, char **error_out);

// Solved footprint comparison; free response/error with seiza_string_free.
char *seiza_mac_sky_overlaps_json(const char *request, char **error_out);

// Prepared color processing; free JSON/error strings with seiza_string_free.
char *seiza_mac_color_tools_json(const char *request, char **error_out);
