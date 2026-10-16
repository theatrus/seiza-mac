#include "seiza_cabi.h"

const char *seiza_mac_core_git_commit(void);
const char *seiza_mac_core_package_version(void);
const char *seiza_mac_core_package_checksum(void);
const char *seiza_mac_core_package_source(void);

// Mac adapters; keep the vendored upstream header unchanged.
char *seiza_mac_distance_catalog_status_json(const char *directory, char **error_out);
bool seiza_mac_catalog_setup_parallax(const char *directory,
    SeizaCatalogSetupProgressCallback progress, void *context, char **error_out);
