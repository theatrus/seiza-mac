mod catalogs;

use std::ffi::c_char;

// Re-exporting the upstream crate makes Cargo include its C ABI implementation
// in this app-owned static library without duplicating or forking that code.
pub use seiza_cabi::*;

static SEIZA_CABI_PACKAGE_VERSION: &[u8] =
    concat!(env!("SEIZA_CABI_PACKAGE_VERSION"), "\0").as_bytes();
static SEIZA_CABI_PACKAGE_CHECKSUM: &[u8] =
    concat!(env!("SEIZA_CABI_PACKAGE_CHECKSUM"), "\0").as_bytes();
static SEIZA_CORE_GIT_COMMIT: &[u8] = concat!(env!("SEIZA_CORE_GIT_COMMIT"), "\0").as_bytes();
static SEIZA_CABI_PACKAGE_SOURCE: &[u8] =
    concat!(env!("SEIZA_CABI_PACKAGE_SOURCE"), "\0").as_bytes();
static SEIZA_PARALLAX_PATCH_COMMIT: &[u8] =
    concat!(env!("SEIZA_PARALLAX_PATCH_COMMIT"), "\0").as_bytes();

/// Returns the upstream renderer fix applied to the published crate, or empty.
#[unsafe(no_mangle)]
pub extern "C" fn seiza_mac_parallax_patch_commit() -> *const c_char {
    SEIZA_PARALLAX_PATCH_COMMIT.as_ptr().cast()
}

/// Returns the exact upstream Git commit of the locked crate.
#[unsafe(no_mangle)]
pub extern "C" fn seiza_mac_core_git_commit() -> *const c_char {
    SEIZA_CORE_GIT_COMMIT.as_ptr().cast()
}

/// Returns the exact seiza-cabi version selected in Cargo.lock.
#[unsafe(no_mangle)]
pub extern "C" fn seiza_mac_core_package_version() -> *const c_char {
    SEIZA_CABI_PACKAGE_VERSION.as_ptr().cast()
}

/// Returns the registry checksum, or an empty string for an exact Git pin.
#[unsafe(no_mangle)]
pub extern "C" fn seiza_mac_core_package_checksum() -> *const c_char {
    SEIZA_CABI_PACKAGE_CHECKSUM.as_ptr().cast()
}

/// Returns Cargo's locked registry or Git source identity.
#[unsafe(no_mangle)]
pub extern "C" fn seiza_mac_core_package_source() -> *const c_char {
    SEIZA_CABI_PACKAGE_SOURCE.as_ptr().cast()
}

#[cfg(test)]
mod tests {
    use std::ffi::CStr;

    #[test]
    fn exports_the_locked_package() {
        let version = unsafe { CStr::from_ptr(super::seiza_mac_core_package_version()) }
            .to_str()
            .expect("version is UTF-8");
        assert!(!version.is_empty());

        let checksum = unsafe { CStr::from_ptr(super::seiza_mac_core_package_checksum()) }
            .to_str()
            .expect("checksum is UTF-8");
        let source = unsafe { CStr::from_ptr(super::seiza_mac_core_package_source()) }
            .to_str()
            .expect("source is UTF-8");
        if source.starts_with("git+") {
            assert!(checksum.is_empty());
        } else {
            assert_eq!(checksum.len(), 64);
            assert!(checksum.bytes().all(|byte| byte.is_ascii_hexdigit()));
        }

        let commit = unsafe { CStr::from_ptr(super::seiza_mac_core_git_commit()) }
            .to_str()
            .expect("commit is UTF-8");
        assert_eq!(commit.len(), 40);
        assert!(commit.bytes().all(|byte| byte.is_ascii_hexdigit()));
        if source.starts_with("git+") {
            assert!(source.ends_with(&format!("rev={commit}#{commit}")));
        }
    }
}
