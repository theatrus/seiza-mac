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
    let source = package_source(&lock, "seiza-cabi")
        .expect("Cargo.lock must contain the upstream seiza-cabi Git package");
    let commit = source
        .rsplit_once('#')
        .map(|(_, commit)| commit)
        .filter(|commit| commit.len() == 40 && commit.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .expect("upstream seiza-cabi source must end in a 40-character Git commit");

    println!("cargo:rustc-env=SEIZA_CORE_GIT_COMMIT={commit}");
}

fn package_source<'a>(lock: &'a str, package_name: &str) -> Option<&'a str> {
    lock.split("[[package]]").skip(1).find_map(|package| {
        let mut name = None;
        let mut source = None;
        for line in package.lines().map(str::trim) {
            if let Some(value) = quoted_value(line, "name") {
                name = Some(value);
            } else if let Some(value) = quoted_value(line, "source") {
                source = Some(value);
            }
        }
        (name == Some(package_name)).then_some(source).flatten()
    })
}

fn quoted_value<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    line.strip_prefix(key)?
        .strip_prefix(" = \"")?
        .strip_suffix('"')
}
