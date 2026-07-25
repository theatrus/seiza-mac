# Auto-update proposal: Sparkle

Status: proposal. This documents the plan for in-app update checks; no code
in this change.

## Goal

The app should tell the user when a new release exists and install it in
place. Today users must watch the GitHub Releases page and download each
DMG by hand.

## Recommendation

Use [Sparkle 2](https://sparkle-project.org) ([GitHub](https://github.com/sparkle-project/Sparkle)),
the standard open-source update framework for Developer ID macOS apps. It is
MIT licensed, actively maintained, and used by most non-App-Store Mac apps.
Our release pipeline already meets its requirements: signed, notarized
builds with stable version numbers and a ZIP artifact per release.

How it works:

- The app embeds Sparkle (SwiftPM package) and a public EdDSA key.
- CI publishes an `appcast.xml` feed describing each release: version,
  download URL, and an EdDSA signature of the archive.
- Sparkle checks the feed on a schedule the user controls, verifies both
  the EdDSA signature and Apple code signing, and swaps the app bundle.

## Integration plan

1. **Add Sparkle** via SwiftPM to the app target. In `Info.plist` set
   `SUFeedURL` to the appcast URL and `SUPublicEDKey` to the public key.
   If the app is sandboxed, add the Sparkle XPC installer service per the
   [sandboxing guide](https://sparkle-project.org/documentation/sandboxing/).
2. **Generate the key once** with Sparkle's `generate_keys`. Store the
   private key as a secret in the protected `signing` environment, next to
   the Developer ID credentials. Publish the public key in the repo.
3. **Extend `release.yml`**: after the ZIP is notarized, run Sparkle's
   `generate_appcast` over the release archives inside the `signing`
   environment, then upload `appcast.xml` as a release asset.
4. **Feed URL**: `https://github.com/theatrus/seiza-mac/releases/latest/download/appcast.xml`
   is stable across releases and needs no extra hosting. If we later want
   staged rollouts or release notes styling, move the feed to GitHub Pages.
5. **UI**: Sparkle provides the standard "Check for Updates…" menu item,
   the update prompt, and the preference for automatic checks. Add the menu
   item to the app menu; no custom UI is required for the first cut.
6. **Release notes**: point each appcast item's release-notes link at the
   matching `docs/releases/` page or the GitHub release body.

## Security notes

- The EdDSA private key lives only in the `signing` environment, with the
  same access rules as the notarization credentials. Pull requests never
  see it.
- Sparkle rejects downgrades and unsigned or tampered archives. Updates are
  double-checked: EdDSA signature plus Apple code-signature validation of
  the new bundle.
- The update check leaks only a version string to GitHub; no separate
  server is involved.

## Alternatives considered

- **App Store distribution** — solves updates but changes sandboxing,
  entitlements, and review constraints; out of scope.
- **Hand-rolled GitHub API check** — a `URLSession` call comparing tags,
  then opening the download page. Less code today, but no signature
  verification, no in-place install, and we would re-implement the prompt,
  scheduling, and skip-this-version logic Sparkle already has.

## Testing

- Unit: feed parsing needs no tests of ours; test only our menu wiring.
- Manual: build two local versions, serve a local appcast, and verify
  prompt, install, relaunch, and downgrade rejection.
- CI: `generate_appcast` runs on the real artifacts, so a dry-run job on a
  branch tag validates the pipeline before the first real release.
