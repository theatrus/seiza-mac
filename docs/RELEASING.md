# Releasing Seiza for macOS

This document covers signing credentials and workflow security. Follow the
operational checklist in [`RELEASE.md`](../RELEASE.md) for every release,
including the release PR, exact-head merge, annotated tag, artifact checks,
download links, and screenshots.

Tags matching `vMAJOR.MINOR.PATCH` build a universal macOS application, package
it as a DMG and ZIP, verify the disk image, produce SHA-256 checksums, and create
a GitHub release. The tag must match the Xcode `MARKETING_VERSION`. The release
job only runs in `theatrus/seiza-mac` for a trusted tag push and enters the
protected GitHub `signing` environment before it can read credentials.

Normal CI runs for every pull request and push to `main`. Its validation job is
unsigned, has read-only repository access, and never receives signing secrets.
After validation passes on an official `main` push, a separate job enters the
protected `signing` environment and uploads a signed, notarized
`Seiza-latest-main` DMG artifact. The signing job is skipped for every pull
request, including pull requests from forks.

An optional signed PR build only starts when the repository owner explicitly
dispatches the reviewed-PR workflow. It validates that the current head commit
is the exact commit the owner approved before it checks out or executes PR code.
For owner-authored PRs, the owner's manual dispatch is the explicit authorization
because GitHub does not allow authors to approve their own pull requests.

## Apple credentials

Two independent Apple credentials are required:

1. A **Developer ID Application** certificate and its private key, exported
   together as a password-protected `.p12`. This signs the Quick Look extension,
   application, and disk image.
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

### Quick Look extension

The Quick Look extension does not need another certificate, API key, secret, or
installer certificate. It is the nested bundle
`Seiza.app/Contents/PlugIns/SeizaQuickLook.appex` with bundle identifier
`fyi.seiza.mac.quicklook`. CI signs it first with the same Developer ID
Application identity and `QuickLook/SeizaQuickLook.entitlements`, then signs the
containing `fyi.seiza.mac` application with `App/Seiza.entitlements`.

The current entitlements only enable the App Sandbox and user-selected
read-only files, so this Developer ID distribution does not require a separate
provisioning profile. If the extension later adopts a restricted capability
such as iCloud, push notifications, or an application group, add the matching
App ID/capability and Developer ID provisioning profile at that time.

## GitHub environment and secrets

In GitHub, open **Settings → Environments**, create an environment named
`signing`, and select **Selected branches and tags**. Allow the `main` branch
for the latest-main and owner-dispatched reviewed PR builds, and allow the
`v*.*.*` tag pattern for releases. A required reviewer is recommended as an
additional gate. Add these six **environment secrets** to that environment, not
to a checked-in file:

- `APPLE_BUILD_CERTIFICATE`: base64-encoded Developer ID Application `.p12`;
- `APPLE_BUILD_CERTIFICATE_PASSWORD`: password chosen when exporting the `.p12`;
- `KEYCHAIN_PASSWORD`: a new random password used only for the ephemeral CI
  keychain;
- `APPLE_API_ISSUER`: App Store Connect API Issuer ID;
- `APPLE_API_KEY`: App Store Connect API Key ID;
- `APPLE_API_KEY_PRIVATE`: base64-encoded App Store Connect `.p8` key.

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

The workflow then:

1. import the Developer ID certificate into an ephemeral keychain;
2. sign the Quick Look extension with its entitlements and hardened runtime;
3. sign the containing app with the app entitlements and hardened runtime;
4. verify the nested signature with `codesign --verify --deep --strict`;
5. submit the app with `xcrun notarytool`, then staple and Gatekeeper-assess it;
6. build and Developer ID sign the DMG;
7. submit, staple, validate, and Gatekeeper-assess the DMG;
8. create checksums only after stapling, then publish the exact verified files.

## Latest main build

The `CI` workflow runs the complete unsigned validation suite for pull requests
and `main`. Only a successful push to `main` in `theatrus/seiza-mac` can upload
the validated unsigned application for the protected signing job. That job
checks out trusted signing inputs at the same commit, validates the application
and Quick Look bundle identifiers and universal binary, signs and notarizes the
app and DMG, and uploads `Seiza-latest-main` with its SHA-256 checksum for 30
days. It does not create or replace a GitHub Release.

If the `signing` environment requires reviewers, approve that deployment to
finish the latest-main artifact. A newer `main` push cancels the older in-flight
CI run so the workflow concentrates signing capacity on the newest commit.

## Reviewed pull-request builds

For a contributor PR, review the current head commit and submit an **Approve**
review as `@theatrus`. Then open **Actions → Reviewed PR DMG → Run workflow**
on `main` and enter the PR number. For an owner-authored PR, use the same manual
dispatch after reviewing the diff.

The authorization job refuses to continue unless:

- the dispatcher is the repository owner;
- the workflow itself is running from `main`;
- the pull request is open and targets `main`;
- the requested commit is still the current PR head; and
- for a non-owner author, the owner's latest review on that exact commit is
  `APPROVED`.

An unsigned macOS job tests and builds the exact reviewed SHA without secrets.
A separate job enters the protected `signing` environment, treats that app as
data, rejects symlinks or unexpected bundle identifiers, signs the Quick Look
extension before its containing app using trusted inputs from `main`, notarizes
and staples a DMG, and uploads it as a 14-day Actions artifact. A new push
changes the head SHA, so the previous approval cannot authorize the new code;
review and dispatch again.

## Publishing

Before tagging, update `MARKETING_VERSION`, commit it to `main`, and make sure
CI is green. Create and push an annotated tag with the same version:

```sh
git tag -a v0.3.0 -m "Seiza 0.3.0"
git push origin v0.3.0
```

The protected `signing` environment may pause the job for reviewer approval.
The API key and Developer ID certificate are only made available after that
gate. The job deletes its temporary keychain, `.p12`, `.p8`, and notarization
archive even when an earlier step fails.

Do not label an artifact signed or notarized until all verification steps pass
on the exact uploaded DMG.
