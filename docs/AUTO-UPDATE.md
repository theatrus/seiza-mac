# In-app updates with Sparkle

Seiza for Mac uses Sparkle 2.9.4 for signed in-app updates. The app can check
for a release on demand, check on a user-controlled schedule, and download and
install an update in place.

## App integration

The app target embeds Sparkle through a pinned Swift package. `App/Info.plist`
contains:

- `SUFeedURL`, which points to the stable GitHub Releases appcast;
- `SUPublicEDKey`, which verifies each release ZIP; and
- `SUEnableInstallerLauncherService`, which lets the sandboxed app install an
  update.

`App/Seiza.entitlements` grants outbound network access and the two Sparkle
installer service names required by a sandboxed app. Seiza already needs
outbound access for catalog setup, so it does not enable Sparkle's separate
downloader service.

The app menu includes **Check for Updates…**. Settings exposes automatic checks
and automatic download and install. Sparkle stores these choices in the app's
preferences; Seiza does not keep a second copy.

## Release feed

Each versioned release contains:

- `Seiza-VERSION-universal.zip`, the full signed update;
- `appcast.xml`, which describes and signs that ZIP;
- the signed and notarized DMG; and
- `SHA256SUMS.txt`.

The app reads:

```text
https://github.com/theatrus/seiza-mac/releases/latest/download/appcast.xml
```

The appcast links to the ZIP under its exact immutable release tag. The release
job runs Sparkle's pinned `generate_appcast` tool after it has signed,
notarized, and packaged the application. The tool reads the private EdDSA key
from standard input and embeds the release notes. The first version ships full
ZIP updates only. Delta updates can be added once the release job retains the
needed older archives.

## Signing

Sparkle adds nested code that must be signed before the outer app. The shared
`scripts/sign-app.sh` script signs, in order:

1. Sparkle's installer and downloader XPC services;
2. Sparkle's `Autoupdate` tool and `Updater.app`;
3. `Sparkle.framework`;
4. the Quick Look preview and thumbnail extensions; and
5. `Seiza.app`.

The release, latest-main, and reviewed-PR signing jobs all use this script.
Unsigned artifacts may contain only Sparkle's known internal symlinks.

The private EdDSA key exists in the maintainer's login Keychain and in the
protected GitHub `signing` environment as `SPARKLE_ED_PRIVATE_KEY`. The public
key is checked into `App/Info.plist`. Pull-request CI cannot read the private
key.

## Version rules

Sparkle compares `CFBundleVersion`, which comes from
`CURRENT_PROJECT_VERSION`. Every release must raise that integer as well as
setting `MARKETING_VERSION` to the version tag. The tag workflow checks the
marketing version, keeps the app and both Quick Look build numbers equal, and
rejects a build number that is not newer than the latest appcast.

The first release that embeds Sparkle is a bootstrap release. Older builds
without Sparkle cannot discover it. The next release is the first end-to-end
test for installed users.

## Checks

- XCTest checks the feed URL, public key, installer service, and embedded
  Sparkle version.
- Pull-request CI builds and tests the app with the pinned package.
- The tag job creates the appcast from the final ZIP and checks its exact
  release URL before publishing.
- A release test must install the prior Sparkle-enabled version, check for the
  new version, install it, relaunch, and confirm the new bundle version.
