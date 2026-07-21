# Releasing Seiza for macOS

This is the operational checklist for a production release. Credential setup,
the protected `signing` environment, and the Quick Look signing model are
documented in [`docs/RELEASING.md`](docs/RELEASING.md).

The release workflow is the only supported publisher. A release tag is
immutable: never move or replace a tag after pushing it.

## 1. Audit the release range

Start from a clean, current `main` and inspect everything since the previous
release:

```sh
git switch main
git pull --ff-only origin main
git fetch --tags origin
git status --short
previous_tag="$(git describe --tags --abbrev=0)"
git log --oneline "${previous_tag}..HEAD"
git diff --stat "${previous_tag}..HEAD"
```

Confirm that the intended release version has not already been tagged or
published:

```sh
version=0.3.0
git rev-parse "v${version}" 2>/dev/null && exit 1 || true
gh release view "v${version}" && exit 1 || true
```

## 2. Prepare a release pull request

Create a release branch and update all version surfaces:

- `MARKETING_VERSION` for the app and Quick Look extension;
- `CURRENT_PROJECT_VERSION` for the app and extension;
- `Rust/seiza-mac-core/Cargo.toml` and `Cargo.lock`;
- the pinned upstream `seiza-cabi` revision when the release intentionally
  adopts a newer Seiza core (the About panel reads its version and exact commit
  from the linked code and lockfile);
- the current-version DMG link and screenshots in `README.md`; and
- release notes or workflow behavior when the release format changes.

Run the same unsigned validation as CI:

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
plutil -lint App/Info.plist App/Seiza.entitlements
plutil -lint QuickLook/Info.plist QuickLook/SeizaQuickLook.entitlements
xcodebuild test \
  -project Seiza.xcodeproj \
  -scheme Seiza \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build \
  -project Seiza.xcodeproj \
  -scheme Seiza \
  -configuration Release \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO \
  'ARCHS=arm64 x86_64'
```

Commit, push, and open a pull request. Review its complete delta before any
signed workflow receives approval.

## 3. Build the exact reviewed PR head

Owner-dispatch the reviewed-PR workflow from trusted `main`:

```sh
pr_number=3
gh workflow run reviewed-pr.yml --ref main -f "pr_number=${pr_number}"
gh run list --workflow reviewed-pr.yml --limit 3
```

Approve the protected `signing` deployment only after confirming the workflow
resolved the current reviewed head. Wait for the unsigned tests, universal
build, nested Quick Look signing, notarization, stapling, Gatekeeper checks, and
artifact upload to pass. Download that artifact and independently check its
checksum and notarization before merging.

## 4. Merge the exact green head

Resolve the current head immediately before merging and protect against a
changed PR:

```sh
head_sha="$(gh pr view "${pr_number}" --json headRefOid --jq .headRefOid)"
gh pr merge "${pr_number}" \
  --squash \
  --delete-branch \
  --match-head-commit "${head_sha}"
git switch main
git pull --ff-only origin main
```

Wait for the resulting `main` CI validation and `Sign latest main DMG` job to
pass. Download the `Seiza-latest-main` artifact, verify its checksum, and confirm
the merge contains the reviewed change range and that the Xcode marketing
version exactly matches the planned tag. This main artifact is an integration
build; the annotated tag still creates the permanent versioned release.

## 5. Create and push the release tag

Create an annotated tag on the verified `main` commit:

```sh
version=0.3.0
test "$(git branch --show-current)" = main
test -z "$(git status --short)"
git tag -a "v${version}" -m "Seiza ${version}"
git push origin "v${version}"
```

The tag push starts `.github/workflows/release.yml`. The workflow refuses a tag
whose version does not match Xcode `MARKETING_VERSION`.

## 6. Approve and monitor publishing

Open the new **Release DMG** Actions run, confirm its tag and commit, then
approve the `signing` environment. Monitor it through release publication:

```sh
gh run list --workflow release.yml --limit 3
gh run watch RUN_ID --exit-status
```

The workflow signs the Quick Look extension before the containing app, signs
and notarizes both the app and DMG, staples their tickets, performs Gatekeeper
checks, creates post-stapling checksums, and publishes the GitHub release.

## 7. Verify the published release

Download the public assets into a fresh directory and verify the exact files a
user receives:

```sh
release_dir="$(mktemp -d /tmp/seiza-release.XXXXXX)"
gh release download "v${version}" --dir "${release_dir}"
cd "${release_dir}"
shasum -a 256 -c SHA256SUMS.txt
hdiutil verify "Seiza-${version}-universal.dmg"
xcrun stapler validate "Seiza-${version}-universal.dmg"
spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "Seiza-${version}-universal.dmg"
```

Finally verify the GitHub release page itself:

- the DMG, ZIP, and checksum links download successfully;
- both application screenshots render;
- GitHub marks the new version as **Latest**;
- the README's current-version download link resolves; and
- the release notes accurately describe the shipped feature set and minimum
  macOS version.

## Failures and corrections

- For a transient GitHub or Apple notarization failure, rerun the failed job on
  the same immutable tag after checking that its commit is still correct.
- For a source, version, packaging, or workflow defect, fix it through another
  reviewed pull request and cut the next patch version. Do not move the failed
  tag to a different commit.
- If a published artifact is defective, make that clear on its release page and
  publish a corrected patch release. Do not silently replace binaries under an
  existing version.
