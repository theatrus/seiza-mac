# In-app updates with Sparkle

Seiza for Mac uses Sparkle 2.9.6 for signed in-app updates. The app can check
for a release on demand, check on a user-controlled schedule, and download and
install an update in place.

## App integration

The app target embeds Sparkle through a pinned Swift package. `App/Info.plist`
contains:

- `SUFeedURL`, which points to our copy of the feed on updates.seiza.fyi;
- `SUPublicEDKey`, which verifies each release ZIP and the feed itself;
- `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`, which make
  Sparkle refuse a feed or ZIP that this key did not sign; and
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

The same feed is published in two places:

```text
https://updates.seiza.fyi/mac/appcast.xml                                  (ours)
https://github.com/theatrus/seiza-mac/releases/latest/download/appcast.xml (GitHub)
```

The release job uploads `appcast.xml` to the GitHub release. A release webhook
then has ec2admin copy it, byte for byte, to updates.seiza.fyi; the copy is
checked against the release's `SHA256SUMS.txt` first. The Windows app has its
own feed under `/windows/`, because the two apps version and release
separately.

Sparkle reads one feed per check, so `UpdateController` picks it through
`feedURLString(for:)`:

- A check the user starts sends a HEAD request to our feed with a five second
  timeout, and uses GitHub if that does not return 200.
- If a check fails to download, parse or verify our feed (`SUAppcastError` or
  `SUAppcastParseError`), it runs once more against GitHub, preserving whether
  the check was manual or scheduled. This also handles a failed GET after a
  successful HEAD probe. For a manual failure, Sparkle shows its normal error
  first; acknowledging it starts the fallback check.
- Check buttons are disabled during the probe. If an automatic check starts
  meanwhile, the manual request waits for that session before choosing its feed.
- Every check after that starts from our feed again.

Builds released before this change read only the GitHub feed, so release CI
must keep publishing it there.

The appcast links to the ZIP under its exact immutable release tag. The release
job runs Sparkle's pinned `generate_appcast` tool after it has signed,
notarized, and packaged the application. The tool reads the private EdDSA key
from standard input and embeds the release notes. Because the app sets
`SURequireSignedFeed`, the tool also signs the whole feed, appending a
`<!-- sparkle-signatures: -->` block. Before publication, the release job uses
Sparkle's `sign_update --verify` to verify the signed feed, rather than relying
on the presence or layout of that block. The first version ships full
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

The tagged-release signing job uses this script. PR and main CI stay unsigned.
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

- XCTest checks the feed URLs, public key, signed-feed keys, installer
  service, embedded Sparkle version, and the feed fallback rules.
- Pull-request CI builds and tests the app with the pinned package.
- The tag job creates the appcast from the final ZIP and checks its exact
  release URL before publishing.
- A release test must install the prior Sparkle-enabled version, check for the
  new version, install it, relaunch, and confirm the new bundle version.

## Signed feed bridge

`SURequireSignedFeed` arrives in the same release that moves the feed to
updates.seiza.fyi. Installed builds without it update normally. The existing
0.8.3 feed is unsigned; the next release generated by this workflow starts
publishing signed feeds. A development build with the new requirement will
reject the old feed on both hosts until that release is published.

Sparkle verifies feeds and archives with the public key. Its default twenty-day
feed-signing failure expiration remains enabled for key rotation recovery;
that recovery strips untrusted feed information and still validates the update.
