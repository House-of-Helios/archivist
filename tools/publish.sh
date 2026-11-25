#!/bin/bash
# Put the code on GitHub (House-of-Helios/archivist), and only the code.
#
# The full history stays on this Mac in `main`, which never leaves. GitHub gets its own line of
# history on the local branch `public`: each run adds one commit holding this commit's files minus
# the private paths below, checked by tools/check-publish.sh before the branch moves, and pushes
# `public` to GitHub's `main`.
#
# Usage:  tools/publish.sh ["what changed"]
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="House-of-Helios/archivist"
# Working notes, research, measurements, dev test scripts and data, the agent's instructions.
PRIVATE=(_Plans _Research _Past _Archive _📚archive _devdata "Sample Data" bench CLAUDE.md THESIS.md $'Icon\r')

[ -z "$(git status --porcelain)" ] || { echo "❌ uncommitted changes — commit first"; exit 1; }
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$REPO.git"
git config remote.origin.push refs/heads/public:refs/heads/main   # a bare `git push` can never send main

INDEX=$(mktemp); trap 'rm -f "$INDEX"' EXIT
export GIT_INDEX_FILE="$INDEX"
git read-tree HEAD
for p in "${PRIVATE[@]}"; do git rm -r -q --cached --ignore-unmatch -- "$p"; done
TREE=$(git write-tree)
unset GIT_INDEX_FILE

PARENT=$(git rev-parse -q --verify refs/heads/public || true)
if [ -n "$PARENT" ] && [ "$(git rev-parse "$PARENT^{tree}")" = "$TREE" ]; then
  echo "🐙 nothing new for GitHub"
else
  MSG="${1:-$(git log -1 --format=%s)}"
  # One fixed name, no e-mail, on every public commit: never this Mac's git identity.
  COMMIT=$(GIT_AUTHOR_NAME="House of Helios" GIT_AUTHOR_EMAIL="" GIT_COMMITTER_NAME="House of Helios" GIT_COMMITTER_EMAIL="" \
    git commit-tree "$TREE" ${PARENT:+-p "$PARENT"} -m "$MSG")
  # Checked before the branch moves: a failing commit never becomes `public`.
  git update-ref refs/heads/publish-candidate "$COMMIT"
  if ! tools/check-publish.sh publish-candidate; then
    git update-ref -d refs/heads/publish-candidate
    echo "❌ privacy check failed — nothing published"; exit 1
  fi
  git update-ref -d refs/heads/publish-candidate
  git update-ref refs/heads/public "$COMMIT"
  echo "🐙 public ← $(git rev-parse --short "$COMMIT") ($MSG)"
fi

# No private path anywhere in `public`'s history.
for c in $(git rev-list public); do
  for p in "${PRIVATE[@]}"; do
    # grep -c, not -q: with pipefail an early grep exit (SIGPIPE) would turn a hit into a pass.
    [ "$(git ls-tree -r -z --name-only "$c" | tr '\0' '\n' | grep -c -e "^$p\$" -e "^$p/")" = 0 ] || { echo "❌ $p is in $c"; exit 1; }
  done
done

git push -q origin public:main
echo "✅ https://github.com/$REPO"
