# Releasing Seiza for macOS

Tags matching `vMAJOR.MINOR.PATCH` build a universal macOS application, package
it as a DMG and ZIP, verify the disk image, produce SHA-256 checksums, and create
a GitHub release. The tag must match the Xcode `MARKETING_VERSION`.

## Current development-preview release

The initial workflow builds with `CODE_SIGNING_ALLOWED=NO`. Its artifacts are
useful for development and early testing but are neither Developer ID signed nor
notarized. macOS may require Control-click → Open.

## Signing and notarization handoff

PSF Guard provides the established credential naming and keychain setup to
reuse. Before changing the workflow to publish production builds, configure
these repository Actions secrets:

- `APPLE_BUILD_CERTIFICATE`: base64-encoded Developer ID Application `.p12`;
- `APPLE_BUILD_CERTIFICATE_PASSWORD`;
- `KEYCHAIN_PASSWORD`;
- `APPLE_API_ISSUER`;
- `APPLE_API_KEY`;
- `APPLE_API_KEY_PRIVATE`: base64-encoded App Store Connect `.p8` key.

The production workflow should then:

1. import the Developer ID certificate into an ephemeral keychain;
2. sign the Quick Look extension and its executable with the extension
   entitlements and hardened runtime;
3. sign the containing app with the app entitlements and hardened runtime;
4. verify the nested signature with `codesign --verify --deep --strict`;
5. build the DMG;
6. submit it with `xcrun notarytool submit --wait` using the API key;
7. staple and validate the ticket with `xcrun stapler`;
8. require `spctl --assess` to pass before publishing.

Do not label an artifact signed or notarized until all verification steps pass
on the exact uploaded DMG.
