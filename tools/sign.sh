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
  codesign --force --deep --options runtime --keychain "$K" -s Archivist "$APP"   # hardened runtime: no library injection into an app that may hold Full Disk Access
else
  echo "warning: no Archivist signing keychain; signing ad hoc (macOS will re-ask permissions after each build)"
  codesign --force --deep --options runtime -s - "$APP"
fi
