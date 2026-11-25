# Archivist — releases

One road: GitHub. `NOTES="what changed" bash tools/release.sh` builds Release, zips it,
signs "<version>\n<sha256>" with the Ed25519 key in the Archivist's signing keychain (_devdata/signing) ("Archivist
release signing"), checks that signature against the public key in `ReleaseFeed.swift`,
pushes and tags, and publishes `Archivist.zip` + `appcast.json` as a GitHub release of
`House-of-Helios/archivist`. Installed apps read the latest release's feed through Tor
on launch and then every hour, and install only a zip whose hash matches and whose
signature verifies. While the repo is private, apps can't read it and say so.

The Dev app (bundle id ending `.dev`) never checks for updates.

Back up the signing key. Without it, installed apps can't take another update.

## Each release
1. Bump `project.yml` → `CFBundleShortVersionString` and `CFBundleVersion`.
   **Not `Archivist/Info.plist`** — `release.sh` runs `xcodegen generate` first, which
   rewrites the plist from `project.yml`, so an edit made to the plist is silently
   reverted and you release the old version number.
2. Commit everything, then `NOTES="what changed" bash tools/release.sh`.
3. Running apps notice the release within the hour and offer **Install & restart** from
   the Archivist pill.

## Update safety
- **Rehearsal gate.** `release.sh` runs `tools/rehearse-update.sh <built app>` before
  anything is published. It copies the frozen v1 fixture
  (`ArchivistCore/Tests/ArchivistCoreTests/Fixtures/v1/`) into a temp folder, records the
  sha256 of every file, runs the built app headless with `--rehearse-launch <dir>` (the
  launch path up to the window: v1 backup, spending folder, PortfolioStore, SpendingStore —
  no window, no network, never the real data folder), then checks: every v1 file
  byte-identical · `backups/pre-2.0.0/` holds identical copies · `spending/schema.json`
  exists · nothing else changed (bar the empty `pricehistory/` cache folder) · a second
  launch changes nothing. Any ❌ aborts the release. Run it alone with
  `bash tools/rehearse-update.sh` (builds Release first) or pass an `.app` path.
- **Install & restart** (`AppSwap` in Core + `AppInstaller`): the zip is
  downloaded and checked (SHA-256, then the signature), unpacked, and while the app still
  runs the new build is copied in beside it as `.Archivist.app.update` (`ditto`) and
  checked (`codesign --verify`, bundle id pinned); then Tor stops, the running bundle and
  the new one trade places by rename, the old one is deleted, the new one opens (`open -n`)
  and the old quits. Nothing is left in Applications. Any failure before the swap leaves
  the app as it was and says why; leftovers of a cut-short swap are cleared at every
  launch. Never touches the data folder.

## Rolling back
No old copy is kept. To go back, release the older code under a higher version number, or
copy an older `Archivist.app` over by hand.

The data folder is shared by every build and is left as it is. If a 2.0 build has to be
undone all the way, the untouched v1 files are also copied in
`~/Library/Application Support/Archivist/backups/pre-2.0.0/`.

## Notes
- The app is ad-hoc signed. The update is unpacked by the app itself, so it isn't
  quarantined and the in-place swap won't re-trigger Gatekeeper after the first manual Open.
- `tools/package.sh` builds a standalone DMG for a first install.
