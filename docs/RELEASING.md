# Releasing Seiza for macOS

Tags matching `vMAJOR.MINOR.PATCH` build a universal macOS application, package
it as a DMG and ZIP, verify the disk image, produce SHA-256 checksums, and create
a GitHub release. The tag must match the Xcode `MARKETING_VERSION`. The release
job only runs in `theatrus/seiza-mac` for a trusted tag push and enters the
protected GitHub `release` environment before it can read credentials.

Normal CI is unsigned. Pull requests whose head repository is not
`theatrus/seiza-mac` are deliberately skipped, so untrusted fork code is never
executed on the hosted macOS runner.

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

## GitHub environment and secrets

In GitHub, open **Settings → Environments**, create an environment named
`release`, and restrict its deployment branches and tags to the `v*.*.*` tag
pattern. A required reviewer is recommended. Add these six **environment
secrets** to that environment, not to a checked-in file:

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
gh secret set APPLE_BUILD_CERTIFICATE --env release < certificate.base64
gh secret set APPLE_BUILD_CERTIFICATE_PASSWORD --env release
gh secret set KEYCHAIN_PASSWORD --env release
gh secret set APPLE_API_ISSUER --env release
gh secret set APPLE_API_KEY --env release
gh secret set APPLE_API_KEY_PRIVATE --env release < api-key.base64
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

## Publishing

Before tagging, update `MARKETING_VERSION`, commit it to `main`, and make sure
CI is green. Create and push an annotated tag with the same version:

```sh
git tag -a v0.1.0 -m "Seiza 0.1.0"
git push origin v0.1.0
```

The protected `release` environment may pause the job for reviewer approval.
The API key and Developer ID certificate are only made available after that
gate. The job deletes its temporary keychain, `.p12`, `.p8`, and notarization
archive even when an earlier step fails.

Do not label an artifact signed or notarized until all verification steps pass
on the exact uploaded DMG.
