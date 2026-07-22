use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    let repository_root = PathBuf::from(
        env::var_os("CARGO_MANIFEST_DIR").expect("Cargo provides CARGO_MANIFEST_DIR"),
    )
    .join("../..");
    let lock_path = repository_root.join("Cargo.lock");
    println!("cargo:rerun-if-changed={}", lock_path.display());

    let lock = fs::read_to_string(&lock_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", lock_path.display()));
    let package =
        package_entry(&lock, "seiza-cabi").expect("Cargo.lock must contain the seiza-cabi package");
    let version = package_field(package, "version")
        .expect("the locked seiza-cabi package must have a version");
    let _source = package_field(package, "source")
        .filter(|source| *source == "registry+https://github.com/rust-lang/crates.io-index")
        .expect("the locked seiza-cabi package must come from crates.io");
    let checksum = package_field(package, "checksum")
        .filter(|checksum| {
            checksum.len() == 64 && checksum.bytes().all(|byte| byte.is_ascii_hexdigit())
        })
        .expect("the locked seiza-cabi package must have a SHA-256 checksum");
    let vcs_path = cargo_registry_vcs_path("seiza-cabi", version)
        .expect("the published seiza-cabi package must contain Cargo VCS metadata");
    println!("cargo:rerun-if-changed={}", vcs_path.display());
    let vcs = fs::read_to_string(&vcs_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", vcs_path.display()));
    let commit = package_vcs_commit(&vcs)
        .expect("the published seiza-cabi package must contain a 40-character Git commit");

    println!("cargo:rustc-env=SEIZA_CABI_PACKAGE_VERSION={version}");
    println!("cargo:rustc-env=SEIZA_CABI_PACKAGE_CHECKSUM={checksum}");
    println!("cargo:rustc-env=SEIZA_CORE_GIT_COMMIT={commit}");
}

fn cargo_registry_vcs_path(package_name: &str, version: &str) -> Option<PathBuf> {
    let cargo_home = env::var_os("CARGO_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".cargo")))?;
    let registry_sources = cargo_home.join("registry/src");
    let package_directory = format!("{package_name}-{version}");
    fs::read_dir(registry_sources)
        .ok()?
        .filter_map(Result::ok)
        .map(|entry| {
            entry
                .path()
                .join(&package_directory)
                .join(".cargo_vcs_info.json")
        })
        .find(|path| path.is_file())
}

fn package_vcs_commit(vcs: &str) -> Option<&str> {
    let commit = vcs
        .lines()
        .map(str::trim)
        .find_map(|line| line.strip_prefix("\"sha1\": \"")?.strip_suffix('"'))?;
    (commit.len() == 40 && commit.bytes().all(|byte| byte.is_ascii_hexdigit())).then_some(commit)
}

fn package_entry<'a>(lock: &'a str, package_name: &str) -> Option<&'a str> {
    lock.split("[[package]]")
        .skip(1)
        .find(|package| package_field(package, "name") == Some(package_name))
}

fn package_field<'a>(package: &'a str, key: &str) -> Option<&'a str> {
    package
        .lines()
        .map(str::trim)
        .find_map(|line| quoted_value(line, key))
}

fn quoted_value<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    line.strip_prefix(key)?
        .strip_prefix(" = \"")?
        .strip_suffix('"')
}
