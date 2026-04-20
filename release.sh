#!/bin/bash
# release.sh — automate the release flow:
#
#   1. Sanity-build with ./build.sh (skip with --skip-build)
#   2. Write $NEW_VERSION to VERSION; commit + push main
#   3. Tag vX.Y.Z; push tag
#   4. Fetch GitHub's source tarball for the tag; compute sha256
#   5. Rewrite url + sha256 in Formula/houdini.rb
#   6. Commit + push the formula update
#
# Usage:
#   ./release.sh 0.3.0
#   ./release.sh 0.3.0 --yes          # skip the confirm prompt
#   ./release.sh 0.3.0 --skip-build   # skip the sanity build
#   ./release.sh --help
#
# Layout:
#   1. Setup           — shell options, cwd
#   2. Output helpers  — colors, step/ok/die, usage()
#   3. Error handling  — stage tracking + ERR trap
#   4. Arguments       — flag + positional parsing
#   5. Configuration   — derived paths, URLs, constants
#   6. Preflight       — tools, git state, version, tag, formula shape
#   7. Confirm         — plan + interactive confirmation
#   8. Release steps   — build → version → tag → sha → formula
#   9. Summary         — final output

# ---------------------------------------------------------------------------
# 1. Setup
# ---------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_ROOT"

# ---------------------------------------------------------------------------
# 2. Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    B="$(tput bold)"; G="$(tput setaf 2)"; Y="$(tput setaf 3)"; R="$(tput setaf 1)"; N="$(tput sgr0)"
else
    B=""; G=""; Y=""; R=""; N=""
fi

step() { printf "%s==>%s %s\n" "$B" "$N" "$1"; }
ok()   { printf "    %s✓%s %s\n" "$G" "$N" "$1"; }
note() { printf "    %s!%s %s\n" "$Y" "$N" "$1"; }
die()  { printf "%s%s: %s%s\n" "$R$B" "$SCRIPT_NAME" "$1" "$N" >&2; exit 1; }

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME <version> [--yes] [--skip-build]

Options:
  --yes          Skip the interactive confirmation prompt.
  --skip-build   Skip ./build.sh sanity check before releasing.
  -h, --help     Show this message.

Example:
  $SCRIPT_NAME 0.3.0
USAGE
}

# ---------------------------------------------------------------------------
# 3. Error handling
# ---------------------------------------------------------------------------
#
# STAGE is updated before each risky step. When the ERR trap fires,
# on_err prints which stage was active and gives concrete recovery
# instructions based on how far the script got.

STAGE="initializing"
TAG=""
TARBALL_URL=""

on_err() {
    local lineno="$1"
    printf "\n%s%s: aborted during '%s' (line %s)%s\n" "$R$B" "$SCRIPT_NAME" "$STAGE" "$lineno" "$N" >&2
    case "$STAGE" in
        pushing_version_commit)
            printf "    local commit exists but push failed. Retry with: git push origin main\n" >&2
            ;;
        pushing_tag)
            printf "    tag %s exists locally but push failed. Retry with: git push origin %s\n" "$TAG" "$TAG" >&2
            ;;
        computing_sha|rewriting_formula|committing_formula)
            printf "    tag %s is already published on origin. To finish by hand:\n" "$TAG" >&2
            printf "      1. SHA=\"\$(curl -fsSL %s | shasum -a 256 | awk '{print \$1}')\"\n" "$TARBALL_URL" >&2
            printf "      2. Update url + sha256 in Formula/houdini.rb\n" >&2
            printf "      3. git add Formula/houdini.rb && git commit -m 'houdini %s' && git push origin main\n" "${TAG#v}" >&2
            printf "    Or unpublish and re-run: git push --delete origin %s && git tag -d %s\n" "$TAG" "$TAG" >&2
            ;;
        pushing_formula)
            printf "    local formula commit exists but push failed. Retry with: git push origin main\n" >&2
            ;;
    esac
    exit 1
}
trap 'on_err $LINENO' ERR

# ---------------------------------------------------------------------------
# 4. Arguments
# ---------------------------------------------------------------------------

YES=0
SKIP_BUILD=0
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)       usage; exit 0 ;;
        -y|--yes)        YES=1 ;;
        --skip-build)    SKIP_BUILD=1 ;;
        --)              shift; POSITIONAL+=("$@"); break ;;
        -*)              die "unknown flag: $1 (see --help)" ;;
        *)               POSITIONAL+=("$1") ;;
    esac
    shift
done
set -- "${POSITIONAL[@]}"

[ $# -eq 1 ] || { usage; exit 1; }
NEW_VERSION="$1"
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "version must be X.Y.Z (got: $NEW_VERSION)"

# ---------------------------------------------------------------------------
# 5. Configuration
# ---------------------------------------------------------------------------

TAG="v$NEW_VERSION"
FORMULA="$PROJECT_ROOT/Formula/houdini.rb"
TARBALL_URL="https://github.com/mgxv/houdini/archive/refs/tags/$TAG.tar.gz"

# SHA-256 of an empty input — if the tarball fetch returns nothing, we
# want to fail loudly instead of writing this into the formula.
EMPTY_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# ---------------------------------------------------------------------------
# 6. Preflight
# ---------------------------------------------------------------------------

# 6a. Tools + files
STAGE="preflight: tools"
step "Checking prerequisites"
for tool in git curl shasum sed awk grep sort; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH"
done
[ -f "$FORMULA" ] || die "$FORMULA missing"
[ -f VERSION ]    || die "VERSION missing"
[ -x ./build.sh ] || die "./build.sh missing or not executable"
ok "tools + files present"

# 6b. Git state
STAGE="preflight: git state"
step "Checking git state"
git remote get-url origin >/dev/null 2>&1 \
    || die "no 'origin' remote configured"
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] \
    || die "not on main (checkout main before releasing)"
git diff-index --quiet HEAD -- \
    || die "working tree has uncommitted changes"
git fetch --quiet origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "local main is not aligned with origin/main — pull or push first"
ok "on main, clean, aligned with origin"

# 6c. Version + tag
STAGE="preflight: version + tag"
step "Checking version + tag"
CURRENT_VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "VERSION file is malformed: '$CURRENT_VERSION'"
[ "$NEW_VERSION" != "$CURRENT_VERSION" ] \
    || die "VERSION is already $NEW_VERSION"
# sort -V treats X.Y.Z lexicographically by segment — fine for this project.
if printf '%s\n%s\n' "$NEW_VERSION" "$CURRENT_VERSION" | sort -VC 2>/dev/null; then
    die "new version $NEW_VERSION is not greater than current $CURRENT_VERSION"
fi
! git rev-parse "$TAG" >/dev/null 2>&1 \
    || die "tag $TAG already exists locally"
! git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 \
    || die "tag $TAG already exists on origin"
ok "$CURRENT_VERSION → $NEW_VERSION; tag $TAG is free"

# 6d. Formula shape
STAGE="preflight: formula shape"
step "Checking formula shape"
grep -qE '/v[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' "$FORMULA" \
    || die "$FORMULA has no recognizable /vX.Y.Z.tar.gz URL pattern"
grep -qE 'sha256 "[^"]+"' "$FORMULA" \
    || die "$FORMULA has no recognizable sha256 \"...\" line"
ok "url + sha256 lines found"

# 6e. Interactivity
STAGE="preflight: interactivity"
if [ $YES -eq 0 ] && [ ! -t 0 ]; then
    die "non-interactive shell — pass --yes to skip confirmation"
fi

# ---------------------------------------------------------------------------
# 7. Confirm
# ---------------------------------------------------------------------------

cat <<PLAN

${B}Plan${N}
  1. $( [ $SKIP_BUILD -eq 1 ] && echo "(skipped) ")Sanity-build with ./build.sh
  2. Bump VERSION → commit "houdini $NEW_VERSION" → push main
  3. Tag $TAG → push tag
  4. Fetch $TARBALL_URL, compute sha256
  5. Rewrite url + sha256 in Formula/houdini.rb
  6. Commit "houdini $NEW_VERSION" → push main

PLAN

if [ $YES -eq 0 ]; then
    read -r -p "Type the version ($NEW_VERSION) to confirm: " confirm
    [ "$confirm" = "$NEW_VERSION" ] || die "aborted"
fi

# ---------------------------------------------------------------------------
# 8. Release steps
# ---------------------------------------------------------------------------

# 8a. Sanity build
if [ $SKIP_BUILD -eq 0 ]; then
    STAGE="sanity_build"
    step "Sanity-building"
    ./build.sh > /dev/null
    ok "build succeeded"
else
    note "sanity build skipped"
fi

# 8b. Bump VERSION → commit → push
STAGE="bumping_version"
step "Bumping VERSION"
echo "$NEW_VERSION" > VERSION
git add VERSION
git commit -m "houdini $NEW_VERSION"
ok "committed"

STAGE="pushing_version_commit"
git push origin main
ok "pushed main"

# 8c. Tag → push
STAGE="tagging"
step "Tagging $TAG"
git tag "$TAG"

STAGE="pushing_tag"
git push origin "$TAG"
ok "pushed $TAG"

# 8d. Fetch tarball → compute sha256
STAGE="computing_sha"
step "Fetching tarball + computing sha256"
TMP_TARBALL="$(mktemp)"
trap 'rm -f "$TMP_TARBALL"; on_err $LINENO' ERR
curl --retry 5 --retry-delay 3 --retry-all-errors -fsSL "$TARBALL_URL" -o "$TMP_TARBALL"
# A complete source tarball of this repo is ≫1KB. Anything smaller is
# almost certainly GitHub returning an error body or an empty response.
TARBALL_BYTES="$(wc -c < "$TMP_TARBALL" | tr -d '[:space:]')"
[ "$TARBALL_BYTES" -ge 1024 ] || die "tarball is suspiciously small ($TARBALL_BYTES bytes)"
SHA="$(shasum -a 256 "$TMP_TARBALL" | awk '{print $1}')"
rm -f "$TMP_TARBALL"
trap 'on_err $LINENO' ERR
[[ "$SHA" =~ ^[a-f0-9]{64}$ ]] || die "unexpected sha256 output: '$SHA'"
[ "$SHA" != "$EMPTY_SHA256" ]  || die "tarball hashed to the empty-input SHA — fetch returned nothing"
ok "sha256 = $SHA ($TARBALL_BYTES bytes)"

# 8e. Rewrite formula
STAGE="rewriting_formula"
step "Rewriting formula"
sed -i.bak -E \
    -e "s|(/v)[0-9]+\.[0-9]+\.[0-9]+(\.tar\.gz)|\1$NEW_VERSION\2|" \
    -e "s|(sha256 \")[^\"]*(\")|\1$SHA\2|" \
    "$FORMULA"
rm "$FORMULA.bak"
grep -q "v$NEW_VERSION.tar.gz" "$FORMULA" || die "url rewrite did not take effect"
grep -q "sha256 \"$SHA\""      "$FORMULA" || die "sha256 rewrite did not take effect"
ok "url + sha256 updated"

# 8f. Commit formula → push
STAGE="committing_formula"
git add "$FORMULA"
git commit -m "houdini $NEW_VERSION"
ok "committed"

STAGE="pushing_formula"
git push origin main
ok "pushed main"

# ---------------------------------------------------------------------------
# 9. Summary
# ---------------------------------------------------------------------------

STAGE="done"
printf "\n%shoudini %s released.%s\n" "$B" "$NEW_VERSION" "$N"
printf "    tag:      %s\n" "$TAG"
printf "    tarball:  %s\n" "$TARBALL_URL"
printf "    sha256:   %s\n" "$SHA"
