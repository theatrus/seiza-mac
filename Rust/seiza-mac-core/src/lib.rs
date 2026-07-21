use std::ffi::c_char;

// Re-exporting the upstream crate makes Cargo include its C ABI implementation
// in this app-owned static library without duplicating or forking that code.
pub use seiza_cabi::*;

static SEIZA_CORE_GIT_COMMIT: &[u8] = concat!(env!("SEIZA_CORE_GIT_COMMIT"), "\0").as_bytes();

/// Returns the exact upstream Seiza commit selected in Cargo.lock.
#[unsafe(no_mangle)]
pub extern "C" fn seiza_mac_core_git_commit() -> *const c_char {
    SEIZA_CORE_GIT_COMMIT.as_ptr().cast()
}

#[cfg(test)]
mod tests {
    use std::ffi::CStr;

    #[test]
    fn exports_the_locked_upstream_commit() {
        let commit = unsafe { CStr::from_ptr(super::seiza_mac_core_git_commit()) }
            .to_str()
            .expect("commit is UTF-8");
        assert_eq!(commit.len(), 40);
        assert!(commit.bytes().all(|byte| byte.is_ascii_hexdigit()));
    }
}
