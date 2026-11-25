#!/bin/bash
# Before anything goes to GitHub: every file and every commit on the branch that leaves (default
# `public`, built by tools/publish.sh; the local full history never leaves) must carry no private
# data: this Mac's home path or user name, e-mail addresses, AI attribution lines, GitHub tokens,
# public IPv4 addresses (private and documentation ranges allowed). Prints counts and where, never
# the matched text. Exit 1 on any finding. Usage: tools/check-publish.sh [ref]
set -uo pipefail
cd "$(dirname "$0")/.."
REF="${1:-public}"
git rev-parse -q --verify "$REF^{commit}" >/dev/null || { echo "no branch $REF"; exit 2; }
ME="$(id -un)"
fail=0
report() { # <label> <text>
  local label="$1" text="$2" n
  n=$(grep -cE "/Users/$ME|$HOME|\b$ME\b" <<<"$text" || true)
  [ "$n" -gt 0 ] && { echo "FOUND: $label: $n line(s) with this Mac's home path or user name"; fail=1; }
  n=$({ grep -oiE '[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}' <<<"$text" || true; } | { grep -viE '^git@|@example\.(com|org)$|@[0-9]x\.(png|jpe?g|pdf|tiff)$' || true; } | sort -u | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && { echo "FOUND: $label: $n e-mail address(es)"; fail=1; }
  # The pattern is split ("co-author"+"ed-by") so this file never matches itself.
  n=$(grep -ciE "co-author""ed-by|generated with \[?claude" <<<"$text" || true)
  [ "$n" -gt 0 ] && { echo "FOUND: $label: $n attribution line(s)"; fail=1; }
  n=$(grep -cE '(github_pat|gh[pousr])_[A-Za-z0-9_]{20,}' <<<"$text" || true)
  [ "$n" -gt 0 ] && { echo "FOUND: $label: $n GitHub token(s)"; fail=1; }
  n=$({ grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' <<<"$text" || true; } \
    | { grep -vE '^(127\.|0\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|255\.|169\.254\.)' || true; } \
    | { grep -vE '^(192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)|^1\.2\.3\.4$' || true; } | sort -u | wc -l | tr -d ' ')
  [[ "$label" == *.svg ]] && n=0   # SVG path data is runs of dotted numbers, never addresses
  [ "$n" -gt 0 ] && { echo "FOUND: $label: $n public IPv4 address(es)"; fail=1; }
  return 0
}
while IFS= read -r -d '' f; do
  text="$(git show "$REF:$f")" || { echo "FOUND: couldn't read $f"; fail=1; continue; }
  grep -qI . <<<"$text" || continue   # binary or empty
  report "$f" "$text"
done < <(git ls-tree -r -z --name-only "$REF")
report "git history of $REF" "$(git log "$REF" -p --no-color -- . ':(exclude)*.svg')"
report "commit authors" "$(git log "$REF" --format='%an <%ae> %cn <%ce>')"
[ $fail -eq 0 ] && echo "publish check: PASS ($REF: every file + its whole history)"
exit $fail
