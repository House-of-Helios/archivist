#!/bin/bash
# Signs the built app with one steady identity ("Archivist", a self-signed certificate in
# _devdata/signing/), so macOS keeps a person's answers (removable volumes, Full Disk Access)
# across rebuilds. Ad-hoc signing changed identity every build and macOS asked again each time.
# Without that keychain (a fresh clone), signs ad hoc as before.
set -e
APP="$1"   # an .app or a .dmg
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
K="$ROOT/_devdata/signing/archivist.keychain-db"
if [ -f "$K" ] && [ -f "$ROOT/_devdata/signing/keychain-password" ]; then
  # The password goes over stdin (`security -i`), never argv; the keychain locks again after.
  printf 'unlock-keychain -p "%s" "%s"\n' "$(cat "$ROOT/_devdata/signing/keychain-password")" "$K" | security -i
  trap 'security lock-keychain "$K" 2>/dev/null' EXIT
  # Hardened runtime on Release (no library injection into an app that may hold Full Disk Access).
  # Not on Debug: Xcode's Archivist.debug.dylib fails library validation under a team-less certificate.
  # Decided from the bundle, not $CONFIGURATION: a Debug app signed with runtime crashed at launch
  # ("different Team IDs") when the variable wasn't set (2026-11-28).
  RUNTIME="--options runtime"; ls "$APP"/Contents/MacOS/*.debug.dylib >/dev/null 2>&1 && RUNTIME=""
  codesign --force --deep $RUNTIME --keychain "$K" -s Archivist "$APP"
else
  echo "warning: no Archivist signing keychain; signing ad hoc (macOS will re-ask permissions after each build)"
  codesign --force --deep --options runtime -s - "$APP"
fi
