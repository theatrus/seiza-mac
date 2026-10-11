# Temporary upstream renderer fixes

This is the published `seiza-parallax` **0.2.0** crate, with only
`src/render.rs` and `src/scene.rs` replaced by those at upstream commit
`da4e14abffdc336f7f1d21d8832342eb8c66f5f7` from
[PR #242](https://github.com/theatrus/seiza/pull/242).

The normalized published Cargo manifest is unchanged, so this patch uses the
released Seiza 0.25.0 dependency family. The PR branch predates the release's
version bumps; a Git override of that branch would pull the older dependencies.
The C ABI and bridge header remain the unmodified published 0.25.0 versions.

The fixes keep a loop moving through its join and keep a bright star's halo
attached to the star, without cutting unmatched halo knots into separate stars.
The upstream regression tests are retained. Run them with
`cargo test --locked -p seiza-parallax --lib` from the repository root.

`PATCH.toml` records the release and fix commits. The app's build metadata and
About details report the additional renderer fix independently of the C ABI's
release commit. Upstream source and licenses are retained; Cargo's cache marker
and redundant nested lockfile are omitted.

When a published parallax release includes these changes, remove the workspace
`[patch.crates-io]` entry, this directory, and its workspace member entry, then
update the lockfile and rerun the native/Rust tests and Iris export. The build
and About metadata automatically omit the patch when its manifest is absent.
