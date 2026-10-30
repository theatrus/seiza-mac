# Releasing Seiza for Mac

This document covers signing credentials and workflow security. Follow the
operational checklist in [`RELEASE.md`](../RELEASE.md) for every release,
including the release PR, exact-head merge, annotated tag, artifact checks,
download links, screenshots, and the required Homebrew cask update.

Tags matching `vMAJOR.MINOR.PATCH` build a universal macOS application, package
it as a DMG and ZIP, create a signed Sparkle appcast, verify the disk image,
produce SHA-256 checksums, and create a GitHub release. The tag must match the
Xcode `MARKETING_VERSION`. The release job only runs in
`theatrus/seiza-mac` for a trusted tag push and enters the protected GitHub
`signing` environment before it can read credentials.

Normal CI runs for every pull request and push to `main`. It validates metadata,
tests Rust and Swift, builds the universal app and both Quick Look extensions,
and verifies an unsigned development DMG. These jobs have read-only repository
access and never enter the signing environment. Only the final release tag is
signed and notarized; PR and main builds do not require signed artifacts.

## Apple credentials

Two independent Apple credentials are required:

1. A **Developer ID Application** certificate and its private key, exported
   together as a password-protected `.p12`. This signs both Quick Look
   extensions, the app, and the disk image.
2. A **team App Store Connect API key** (`AuthKey_<KEY_ID>.p8`) with Developer
   access or higher. Record its Key ID and Issuer ID when it is created; the
   private key can only be downloaded once. Do not use an individual API key:
   this workflow authenticates `notarytool` with the team's Issuer ID.

Do not use a Mac App Distribution, Apple Development, Developer ID Installer,
or `.cer` file by itself. The `.p12` must contain the Developer ID Application
private key as well as the certificate.

The Apple Account Holder creates the Developer ID certificate under
**Certificates, Identifiers & Profiles → Certificates → + → Developer ID →
Developer ID Application** using a certificate-signing request from the Mac
that will hold the private key. After installing the downloaded `.cer`, export
the resulting identity from **Keychain Access → My Certificates** as `.p12`.

For notarization, an Account Holder first enables App Store Connect API access.
An Account Holder or Admin then creates the team key under **App Store Connect →
Users and Access → Integrations → Team Keys** and downloads its `.p8` exactly
once. The existing PSF Guard certificate and team API key may be reused when
both applications are distributed by the same Apple Developer team.

### Quick Look extensions

The Quick Look extensions do not need another Apple certificate, API key,
secret, or installer certificate. They are the nested bundles
`Seiza.app/Contents/PlugIns/SeizaQuickLook.appex` and
`Seiza.app/Contents/PlugIns/SeizaThumbnail.appex`, with bundle identifiers
`fyi.seiza.mac.quicklook` and `fyi.seiza.mac.thumbnail`. CI signs each with the
same Developer ID Application identity and the shared
`QuickLook/SeizaQuickLook.entitlements` file, then signs the containing
`fyi.seiza.mac` app with `App/Seiza.entitlements`.

The current entitlements only enable the App Sandbox and user-selected
read-only files, so this Developer ID distribution does not require a separate
provisioning profile. If either extension later adopts a restricted capability
such as iCloud, push notifications, or an application group, add the matching
App ID/capability and Developer ID provisioning profile at that time.

## GitHub environment and secrets

In GitHub, open **Settings → Environments**, create an environment named
`signing`, and select **Selected branches and tags**. Allow only the
`v*.*.*` tag pattern for releases. A required reviewer is recommended as an
additional gate. Add these seven **environment secrets** to that environment, not
to a checked-in file:

- `APPLE_BUILD_CERTIFICATE`: base64-encoded Developer ID Application `.p12`;
- `APPLE_BUILD_CERTIFICATE_PASSWORD`: password chosen when exporting the `.p12`;
- `KEYCHAIN_PASSWORD`: a new random password used only for the ephemeral CI
  keychain;
- `APPLE_API_ISSUER`: App Store Connect API Issuer ID;
- `APPLE_API_KEY`: App Store Connect API Key ID;
- `APPLE_API_KEY_PRIVATE`: base64-encoded App Store Connect `.p8` key; and
- `SPARKLE_ED_PRIVATE_KEY`: the private key exported by Sparkle's
  `generate_keys` tool.

Generate the two base64 values on macOS without copying binary data into the
shell history:

```sh
/usr/bin/base64 < DeveloperIDApplication.p12 | tr -d '\n' > certificate.base64
/usr/bin/base64 < AuthKey_KEYID.p8 | tr -d '\n' > api-key.base64
openssl rand -base64 32
```

Paste the first file into `APPLE_BUILD_CERTIFICATE`, the second into
`APPLE_API_KEY_PRIVATE`, and use the random value as `KEYCHAIN_PASSWORD`. Delete
the two temporary `.base64` files afterward and retain the original credentials
in a secure credential store.

The same secrets can be installed with GitHub CLI after the environment exists:

```sh
gh secret set APPLE_BUILD_CERTIFICATE --env signing < certificate.base64
gh secret set APPLE_BUILD_CERTIFICATE_PASSWORD --env signing
gh secret set KEYCHAIN_PASSWORD --env signing
gh secret set APPLE_API_ISSUER --env signing
gh secret set APPLE_API_KEY --env signing
gh secret set APPLE_API_KEY_PRIVATE --env signing < api-key.base64
```

Generate the Sparkle key once with the pinned tool from Xcode's resolved
package artifacts:

```sh
xcodebuild -resolvePackageDependencies \
  -project Seiza.xcodeproj \
  -scheme Seiza \
  -derivedDataPath DerivedData
sparkle_tools=DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
"${sparkle_tools}/generate_keys" --account fyi.seiza.mac
"${sparkle_tools}/generate_keys" \
  --account fyi.seiza.mac \
  -x sparkle-private-key
gh secret set SPARKLE_ED_PRIVATE_KEY --env signing < sparkle-private-key
rm -P sparkle-private-key
```

Keep the generated key in the maintainer's login Keychain. Copy the printed
public key to `SUPublicEDKey` in `App/Info.plist`.

The workflow then:

1. import the Developer ID certificate into an ephemeral keychain;
2. sign Sparkle's XPC services, helper tools, and framework;
3. sign both Quick Look extensions and the containing app with their
   entitlements;
4. verify the nested signature with `codesign --verify --deep --strict`;
5. submit the app with `xcrun notarytool`, then staple and Gatekeeper-assess it;
6. build and Developer ID sign the DMG;
7. submit, staple, validate, and Gatekeeper-assess the DMG;
8. sign the final ZIP and generate `appcast.xml` with Sparkle; and
9. create checksums only after stapling, then publish the exact verified files.

## Unsigned CI builds

The `CI` workflow runs the complete unsigned validation suite for pull requests
and `main`. Review and merge the exact PR head after its checks pass, then wait
for unsigned CI on the merged `main` commit before tagging. A newer `main` push
cancels the older in-flight CI run. There is no separate PR or main signing job.

## Publishing

Before tagging, update `MARKETING_VERSION`, raise `CURRENT_PROJECT_VERSION`,
commit both to `main`, and make sure CI is green. Create and push an annotated
tag with the same marketing version:

```sh
version=0.9.0
git tag -a "v${version}" -m "Seiza for Mac ${version}"
git push origin "v${version}"
```

The protected `signing` environment may pause the job for reviewer approval.
The API key and Developer ID certificate are only made available after that
gate. The job deletes its temporary keychain, `.p12`, `.p8`, and notarization
archive even when an earlier step fails.

Do not label an artifact signed or notarized until all verification steps pass
on the exact uploaded DMG.

## Packaging space

After the universal app is built and validated, the signing job removes only
Cargo outputs, the copied Rust archive and Xcode intermediates. It retains the
app in `DerivedData/Build/Products/Release` and Sparkle tools in
`DerivedData/SourcePackages`. The temporary app notarization ZIP is removed once
its ticket is stapled and verified. Disk usage is logged around cleanup.

The DMG uses logical file sizes plus 25% and 64 MiB of headroom. Automatic image
sizing can underestimate sparse files, resulting in ENOSPC while copying the
app even when the host has free storage. Explicit capacity also leaves room for
filesystem metadata and extended attributes. A local regression fixture with a
512 MiB sparse file and a resource fork fails with automatic sizing and passes
with explicit sizing, including byte-for-byte reads from the mounted image.

Unsigned CI retains Cargo outputs for the post-job Rust cache, removing only
linked Rust archives and Xcode intermediates before creating its development
DMG. CI and signed publishing use GitHub's standard Apple silicon `macos-26`
runner. Both architectures are built and checked in the universal app; an Intel
host is not required for publishing. The deployment target remains macOS 15.
Native tests also passed on Intel during
0.8.5 validation. See GitHub's
[hosted runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
for the available standard labels.

The native test suite runs serially for clear per-test CI diagnostics. A failed
native run prints its xcresult summary, with a legacy JSON fallback. Tour tests
select fixture catalogues through the session input path rather than creating
persistent security-scoped bookmarks, which require an app-scope key unavailable
to the unsigned Intel test host.
