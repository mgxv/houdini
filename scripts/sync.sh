#!/bin/bash
# sync.sh — refresh vendor/mediaremote-adapter/ from the latest
# ungive/mediaremote-adapter release, then commit + push.
#
# Slim-copy semantics: every file already in vendor/mediaremote-adapter/
# gets overwritten from its upstream counterpart if one exists. Files
# missing upstream are left alone; new upstream files are NOT added.
# The vendored shape stays curated to what scripts/build.sh compiles.
#
# Usage: ./scripts/sync.sh
#
# Preconditions (enforced by preflight): on main, clean working tree,
# aligned with origin/main. On success: one commit ("sync
# mediaremote-adapter vX.Y.Z") pushed to origin/main. If vendor/ already
# matches upstream, exits without touching git.

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

VENDOR="vendor/mediaremote-adapter"
REPO="ungive/mediaremote-adapter"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    B="$(tput bold)"; G="$(tput setaf 2)"; Y="$(tput setaf 3)"; R="$(tput setaf 1)"; N="$(tput sgr0)"
else
    B=""; G=""; Y=""; R=""; N=""
fi

step() { printf "%s==>%s %s\n" "$B" "$N" "$1"; }
ok()   { printf "    %s✓%s %s\n" "$G" "$N" "$1"; }
info() { printf "    %s\n" "$1"; }
note() { printf "    %s!%s %s\n" "$Y" "$N" "$1"; }
die()  { printf "%s%s: %s%s\n" "$R$B" "$SCRIPT_NAME" "$1" "$N" >&2; exit 1; }

# Echo `$ cmd` (to stderr so it's safe inside $(...) captures) and run it.
run() {
    printf "    %s\$%s %s\n" "$B" "$N" "$*" >&2
    "$@"
}

trap 'die "failed near line $LINENO"' ERR

# ---------------------------------------------------------------------------
# Preflight — tools, vendor tree, git state
# ---------------------------------------------------------------------------

step "Checking prerequisites"
for tool in curl shasum tar awk git cmp; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH"
done
[ -d "$VENDOR" ] \
    || die "$VENDOR/ not found — run from a clone of the houdini repo"
ok "tools + vendor tree present"

step "Checking git state"
git remote get-url origin >/dev/null 2>&1 \
    || die "no 'origin' remote configured"
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] \
    || die "not on main (checkout main before syncing)"
git update-index --refresh >/dev/null || true   # avoid stale-stat false positives below
git diff-index --quiet HEAD -- \
    || die "working tree has uncommitted changes — commit or stash first"
git fetch --quiet origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "local main is not aligned with origin/main — pull or push first"
ok "on main, clean, aligned with origin"

# ---------------------------------------------------------------------------
# Resolve latest tag — follow GitHub's /releases/latest 302 redirect to
# /releases/tag/vX.Y.Z and take the last path component. No API rate
# limits, no auth, no `gh` dependency.
# ---------------------------------------------------------------------------

step "Resolving latest $REPO release"
LATEST_URL="https://github.com/$REPO/releases/latest"
FINAL_URL="$(curl -sSIL -o /dev/null -w '%{url_effective}' "$LATEST_URL")"
TAG="$(printf '%s' "$FINAL_URL" | awk -F/ '{print $NF}' | tr -d '[:space:]')"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "could not parse tag from redirect URL: '$FINAL_URL'"
ok "latest: $TAG"

# ---------------------------------------------------------------------------
# Fetch + extract tarball
# ---------------------------------------------------------------------------

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

step "Fetching $TAG tarball"
TARBALL_URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
run curl --retry 5 --retry-delay 3 --retry-all-errors -fsSL \
    "$TARBALL_URL" -o "$TMPDIR/src.tgz"
TARBALL_BYTES="$(wc -c < "$TMPDIR/src.tgz" | tr -d '[:space:]')"
# A real source tarball is ≫1 KiB; anything smaller means GitHub returned
# an error body or an empty response.
[ "$TARBALL_BYTES" -ge 1024 ] \
    || die "tarball suspiciously small ($TARBALL_BYTES bytes)"
SHA="$(shasum -a 256 "$TMPDIR/src.tgz" | awk '{print $1}')"
ok "fetched $TARBALL_BYTES bytes (sha256=$SHA)"

step "Extracting"
run tar -xzf "$TMPDIR/src.tgz" -C "$TMPDIR"
UPSTREAM="$TMPDIR/mediaremote-adapter-${TAG#v}"
[ -d "$UPSTREAM" ] || die "expected extracted dir missing: $UPSTREAM"
ok "extracted to $UPSTREAM"

# ---------------------------------------------------------------------------
# Slim-copy — overwrite files that exist in both trees and differ. `cp`
# preserves mode on macOS, so mediaremote-adapter.pl stays executable
# without a chmod call.
# ---------------------------------------------------------------------------

step "Slim-copying into $VENDOR"
updated=0
total=0
while IFS= read -r rel; do
    total=$((total + 1))
    src="$UPSTREAM/$rel"
    dst="$VENDOR/$rel"
    [ -f "$src" ] || continue
    cmp -s "$src" "$dst" && continue
    cp "$src" "$dst"
    printf "    updated %s\n" "$rel"
    updated=$((updated + 1))
done < <(cd "$VENDOR" && find . -type f ! -name '.DS_Store' | sed 's|^\./||' | sort)

if [ "$updated" -eq 0 ]; then
    ok "vendor already matches $TAG — nothing to commit"
    exit 0
fi
ok "$updated of $total files updated"

# ---------------------------------------------------------------------------
# Commit + push — `git add .` is safe because the clean-tree preflight
# above guarantees the diff is only the sync (no stray WIP).
# ---------------------------------------------------------------------------

step "Committing and pushing"
run git add .
run git commit -m "sync mediaremote-adapter $TAG"
run git push origin main
ok "pushed main"

printf "\n%sSynced to mediaremote-adapter %s.%s\n" "$B" "$TAG" "$N"
