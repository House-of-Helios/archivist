#!/bin/bash
# Publish a release to GitHub (House-of-Helios/archivist): the public way updates travel.
# Every Mac reads `appcast.json` from the latest release and installs `Archivist.zip`
# only if its SHA-256 matches and the signature verifies (ReleaseFeed.swift). This is the
# only way the app updates.
#
# Usage:  NOTES="what changed" bash tools/release.sh
#
# - Built in its own derived-data folder, apart from the dev and rehearsal builds.
# - The feed is signed with the Ed25519 key "Archivist release signing" in Archivist's own
#   signing keychain (_devdata/signing/, never in git); the app with the steady "Archivist"
#   certificate (tools/sign.sh), so people's permission answers survive updates.
#   Lose that key and installed apps can't take updates any more: back it up.
# - Publishes the code first (tools/publish.sh: the `public` branch, private paths left
#   out) and tags that commit v<version>, so a release is always code that's on GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="House-of-Helios/archivist"
PROJECT="Archivist.xcodeproj"; SCHEME="Archivist"
DERIVED="dist/ReleaseDerivedData"
OUT="dist/release"
command -v xcodegen >/dev/null && xcodegen generate >/dev/null 2>&1 || true
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Archivist/Info.plist)
NOTES="${NOTES:?NOTES=\"what changed\" is required}"
TAG="v$VERSION"

[ -z "$(git status --porcelain)" ] || { echo "❌ uncommitted changes — commit first"; exit 1; }
gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 && { echo "❌ $TAG is already released — bump the version in project.yml"; exit 1; }
K="$PWD/_devdata/signing/archivist.keychain-db"
printf 'unlock-keychain -p "%s" "%s"\n' "$(cat _devdata/signing/keychain-password)" "$K" | security -i   # stdin, never argv
trap 'security lock-keychain "$K" 2>/dev/null' EXIT
PRIV=$(security find-generic-password -s "Archivist release signing" -a archivist -w "$K") \
  || { echo "❌ no release signing key in Archivist's signing keychain"; exit 1; }

echo "🔨 build Release $TAG (signed by tools/sign.sh)"
rm -rf "$DERIVED"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -derivedDataPath "$DERIVED" -destination "generic/platform=macOS" ONLY_ACTIVE_ARCH=NO build >/dev/null   # both Apple silicon and Intel
APP="$DERIVED/Build/Products/Release/Archivist.app"
[ -d "$APP" ] || { echo "❌ app not found"; exit 1; }
[ "$(lipo -archs "$APP/Contents/MacOS/Archivist")" = "x86_64 arm64" ] || { echo "❌ not universal (Apple silicon + Intel)"; exit 1; }

codesign -d -r- "$APP" 2>&1 | grep -q 'certificate' || { echo "❌ not signed with the Archivist certificate — permissions would reset on update"; exit 1; }
[ -f "$APP/Contents/Library/LaunchAgents/com.houseofhelios.archivist.scheduler.plist" ] || { echo "❌ scheduler agent missing from the app"; exit 1; }
# Nothing of the dev build (remote control, snapshots) and no path of this Mac in the release binary.
BIN="$APP/Contents/MacOS/Archivist"
! nm "$BIN" 2>/dev/null | grep -q 'DevControl\|Snapshot' || { echo "❌ Debug-only code (DevControl/Snapshot) is in the release binary"; exit 1; }
! strings "$BIN" | grep -q '/Users/' || { echo "❌ a /Users/ path is in the release binary"; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Archivist.zip"   # for the in-app updater
# For people: a disk image with the app and an Applications shortcut to drag it onto.
STAGE=$(mktemp -d); cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Archivist" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Archivist.dmg" >/dev/null
rm -rf "$STAGE"
# The DMG stays unsigned: Gatekeeper rejects a disk image signed by a certificate Apple does
# not know (a second "Open Anyway"), but simply mounts an unsigned one. The app inside is signed.
(cd "$OUT" && shasum -a 256 Archivist.dmg > Archivist.dmg.sha256)
(cd "$OUT" && shasum -a 256 Archivist.zip > Archivist.zip.sha256)
SHA=$(cut -d' ' -f1 "$OUT/Archivist.zip.sha256")
SIG=$(printf '%s\n' "$PRIV" | swift tools/release-sign.swift sign "$VERSION" "$SHA")
# The key the installed apps trust is the one baked into ReleaseFeed.swift. If the Keychain
# key isn't its pair, every app would refuse this release: stop here instead.
PUB=$(sed -n 's/.*publicKeyBase64 = "\(.*\)".*/\1/p' ArchivistCore/Sources/ArchivistCore/ReleaseFeed.swift)
swift tools/release-sign.swift verify "$PUB" "$VERSION" "$SHA" "$SIG" >/dev/null \
  || { echo "❌ the signing keychain's key doesn't match the app's public key — not released"; exit 1; }

# The last release's feed seeds the change log, newest first.
gh release download -R "$REPO" --pattern appcast.json --output "$OUT/previous.json" 2>/dev/null || echo "(no earlier release: the change log starts here)"
VERSION="$VERSION" NOTES="$NOTES" SHA="$SHA" SIG="$SIG" python3 - "$OUT/previous.json" > "$OUT/appcast.json" <<'PY'
import json, os, sys
try:
    old = json.load(open(sys.argv[1]))
except Exception:
    old = {}
v = os.environ["VERSION"]
history = [{"version": v, "notes": os.environ["NOTES"]}] + [h for h in old.get("history", []) if h.get("version") != v]
json.dump({"version": v, "notes": os.environ["NOTES"], "file": "Archivist.zip",
           "sha256": os.environ["SHA"], "signature": os.environ["SIG"], "history": history[:30]},
          sys.stdout, indent=1, ensure_ascii=False)
PY
rm -f "$OUT/previous.json"

tools/publish.sh "Archivist $VERSION — $NOTES"
git tag -a "$TAG" -m "Archivist $VERSION" public && git push -q origin "$TAG"

echo "📦 release $TAG"
gh release create "$TAG" -R "$REPO" --title "Archivist $VERSION" --notes "$NOTES

**Install:** download **Archivist.dmg**, open it, drag Archivist onto Applications. First open: see [\"Archivist can't be opened\"](https://github.com/$REPO#archivist-cant-be-opened)." \
  "$OUT/Archivist.dmg" "$OUT/Archivist.zip" "$OUT/appcast.json"   # the zip's fingerprint lives in the signed appcast

# Verify by download, as a user's app would get it: hash, signature, code signature, version.
CHECK=$(mktemp -d); trap 'rm -rf "$CHECK"; security lock-keychain "$K" 2>/dev/null' EXIT
gh release download "$TAG" -R "$REPO" --dir "$CHECK"
(cd "$OUT" && cp Archivist.zip.sha256 Archivist.dmg.sha256 "$CHECK/") && (cd "$CHECK" && shasum -a 256 -c Archivist.zip.sha256 >/dev/null && shasum -a 256 -c Archivist.dmg.sha256 >/dev/null) \
  || { echo "❌ a download doesn't match what was built"; exit 1; }
hdiutil attach -nobrowse -readonly -mountpoint "$CHECK/dmg" "$CHECK/Archivist.dmg" >/dev/null && [ -d "$CHECK/dmg/Archivist.app" ] && [ -L "$CHECK/dmg/Applications" ] \
  || { echo "❌ the DMG doesn't hold Archivist.app and the Applications shortcut"; exit 1; }
hdiutil detach "$CHECK/dmg" >/dev/null
swift tools/release-sign.swift verify "$PUB" "$VERSION" "$SHA" "$SIG" >/dev/null || { echo "❌ downloaded feed's signature doesn't verify"; exit 1; }
ditto -x -k "$CHECK/Archivist.zip" "$CHECK/app"
codesign --verify --strict --deep -R "=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')" "$CHECK/app/Archivist.app" || { echo "❌ downloaded app's code signature fails"; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$CHECK/app/Archivist.app/Contents/Info.plist")" = "$VERSION" ] \
  || { echo "❌ downloaded app is not $VERSION"; exit 1; }
echo "🔍 verified by download: checksum, signature, code signature, version"
echo "✅ released $TAG — https://github.com/$REPO/releases/tag/$TAG"
