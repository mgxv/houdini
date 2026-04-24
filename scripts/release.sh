#!/bin/bash
# release.sh — publish a new houdini release.
#
# Flow (what the plan prompt shows the user):
#   1. Sanity-build             (scripts/build.sh; skip with --skip-build)
#   2. Bump Sources/Version.swift → commit + push main
#   3. Tag vX.Y.Z               → push tag (publishes the GitHub tarball)
#   4. Fetch tarball            → compute sha256
#   5. Rewrite url + sha256     in Formula/houdini.rb (this repo)
#   6. Commit formula update    → push main
#   7. Mirror                   cp Formula/houdini.rb → mgxv/homebrew-houdini
#   8. Commit tap formula       → push tap
#
# The in-repo Formula/houdini.rb is authoritative; the tap is a mirror
# overwritten unconditionally by the mirror step. You can edit the
# in-repo formula freely between releases — the release flow syncs it
# to the tap. The tap repo (mgxv/homebrew-houdini) is what
# `brew install` actually reads.
#
# Usage:
#   ./scripts/release.sh 0.3.0
#   ./scripts/release.sh 0.3.0 --yes         # skip the confirm prompt
#   ./scripts/release.sh 0.3.0 --skip-build  # skip the sanity build
#   ./scripts/release.sh --help
#
# Env:
#   HOUDINI_TAP  path to the mgxv/homebrew-houdini clone
#                (default: $PROJECT_ROOT/../homebrew-houdini)

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

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
note() { printf "    %s!%s %s\n" "$Y" "$N" "$1"; }
die()  { printf "%s%s: %s%s\n" "$R$B" "$SCRIPT_NAME" "$1" "$N" >&2; exit 1; }

# Echo a command (prefixed `$ `) then execute it. Echo goes to stderr
# so it's safe inside $(...) captures and pipelines — the command's
# real stdout stays on stdout for the caller to consume or display.
# Quotes aren't reproduced (args are joined with spaces); refer to the
# script for exact invocations.
run() {
    printf "    %s\$%s %s\n" "$B" "$N" "$*" >&2
    "$@"
}

# Echo a literal command line without executing. Used for shell
# constructs (redirects, pipes, assignments) where wrapping with run()
# would either silence the echo or hide the important detail — the
# caller runs the actual command on the next line.
say() {
    printf "    %s\$%s %s\n" "$B" "$N" "$*" >&2
}

usage() {
    cat <<USAGE
Usage: $SCRIPT_NAME <version> [--yes] [--skip-build]

Options:
  --yes          Skip the interactive confirmation prompt.
  --skip-build   Skip scripts/build.sh sanity check before releasing.
  -h, --help     Show this message.

Env:
  HOUDINI_TAP    Path to the mgxv/homebrew-houdini clone.
                 Default: \$PROJECT_ROOT/../homebrew-houdini

Example:
  $SCRIPT_NAME 0.3.0
USAGE
}

# ---------------------------------------------------------------------------
# Error handling
#
# Every risky operation assigns $STAGE before running. on_err reads it
# and prints concrete recovery instructions tailored to how far we got.
# ---------------------------------------------------------------------------

STAGE="initializing"
TAG=""
NEW_VERSION=""
TARBALL_URL=""
TAP_DIR=""
TAP_FORMULA=""
TAP_BRANCH=""
IN_REPO_FORMULA=""

on_err() {
    local lineno="$1"
    printf "\n%s%s: aborted during '%s' (line %s)%s\n" \
        "$R$B" "$SCRIPT_NAME" "$STAGE" "$lineno" "$N" >&2
    case "$STAGE" in
        pushing_version_commit)
            printf "    local commit exists but push failed. Retry with: git push origin main\n" >&2
            ;;
        pushing_tag)
            printf "    tag %s exists locally but push failed. Retry with: git push origin %s\n" "$TAG" "$TAG" >&2
            ;;
        computing_sha|rewriting_in_repo_formula|committing_in_repo_formula)
            printf "    tag %s is already published but the formula update hasn't landed. To finish by hand:\n" "$TAG" >&2
            printf "      1. SHA=\"\$(curl -fsSL %s | shasum -a 256 | awk '{print \$1}')\"\n" "$TARBALL_URL" >&2
            printf "      2. Update url + sha256 in %s\n" "$IN_REPO_FORMULA" >&2
            printf "      3. git add Formula/houdini.rb && git commit -m 'houdini %s formula' && git push origin main\n" "$NEW_VERSION" >&2
            printf "      4. cp %s %s\n" "$IN_REPO_FORMULA" "$TAP_FORMULA" >&2
            printf "      5. (cd %s && git add Formula/houdini.rb && git commit -m 'houdini %s' && git push origin %s)\n" \
                "$TAP_DIR" "$NEW_VERSION" "$TAP_BRANCH" >&2
            printf "    Or unpublish and re-run: git push --delete origin %s && git tag -d %s\n" "$TAG" "$TAG" >&2
            ;;
        pushing_in_repo_formula_commit)
            printf "    in-repo formula commit exists locally but push failed. Retry with: git push origin main\n" >&2
            printf "    Then: cp %s %s && (cd %s && git add Formula/houdini.rb && git commit -m 'houdini %s' && git push origin %s)\n" \
                "$IN_REPO_FORMULA" "$TAP_FORMULA" "$TAP_DIR" "$NEW_VERSION" "$TAP_BRANCH" >&2
            ;;
        mirroring_to_tap|committing_tap_formula)
            printf "    in-repo formula is already updated and pushed. To finish the tap mirror by hand:\n" >&2
            printf "      1. cp %s %s\n" "$IN_REPO_FORMULA" "$TAP_FORMULA" >&2
            printf "      2. (cd %s && git add Formula/houdini.rb && git commit -m 'houdini %s' && git push origin %s)\n" \
                "$TAP_DIR" "$NEW_VERSION" "$TAP_BRANCH" >&2
            ;;
        pushing_tap_formula)
            printf "    tap commit exists locally but push failed. Retry with:\n" >&2
            printf "      (cd %s && git push origin %s)\n" "$TAP_DIR" "$TAP_BRANCH" >&2
            ;;
    esac
    exit 1
}
trap 'on_err $LINENO' ERR

# Run any command inside the tap clone. Keeps (cd … && git …) out of
# the five places we touch the tap.
tap() { (cd "$TAP_DIR" && "$@"); }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

YES=0
SKIP_BUILD=0
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)     usage; exit 0 ;;
        -y|--yes)      YES=1 ;;
        --skip-build)  SKIP_BUILD=1 ;;
        --)            shift; POSITIONAL+=("$@"); break ;;
        -*)            die "unknown flag: $1 (see --help)" ;;
        *)             POSITIONAL+=("$1") ;;
    esac
    shift
done
set -- "${POSITIONAL[@]}"

[ $# -eq 1 ] || { usage; exit 1; }
NEW_VERSION="$1"
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "version must be X.Y.Z (got: $NEW_VERSION)"

TAG="v$NEW_VERSION"
TAP_DIR="${HOUDINI_TAP:-$PROJECT_ROOT/../homebrew-houdini}"
TAP_FORMULA="$TAP_DIR/Formula/houdini.rb"
IN_REPO_FORMULA="$PROJECT_ROOT/Formula/houdini.rb"
TARBALL_URL="https://github.com/mgxv/houdini/archive/refs/tags/$TAG.tar.gz"

# SHA-256 of empty input — if curl silently returns nothing, we'd
# compute this. Compared after hashing so it never reaches the formula.
EMPTY_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# ---------------------------------------------------------------------------
# Preflight — all read-only. No writes happen until every check passes.
# ---------------------------------------------------------------------------

STAGE="preflight: tools"
step "Checking prerequisites"
for tool in git curl shasum sed awk grep sort; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH"
done
[ -d "$TAP_DIR/.git" ]          || die "tap repo not found at $TAP_DIR — clone mgxv/homebrew-houdini there or set HOUDINI_TAP"
[ -f "$TAP_FORMULA" ]           || die "tap formula missing: $TAP_FORMULA"
[ -f "$IN_REPO_FORMULA" ]       || die "in-repo formula missing: $IN_REPO_FORMULA"
[ -f Sources/Version.swift ]    || die "Sources/Version.swift missing"
[ -x scripts/build.sh ]         || die "scripts/build.sh missing or not executable"
ok "tools + files present (tap at $TAP_DIR)"

STAGE="preflight: git state (source)"
step "Checking git state (this repo)"
git remote get-url origin >/dev/null 2>&1 \
    || die "no 'origin' remote configured"
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] \
    || die "not on main (checkout main before releasing)"
# Refresh stat info in the index before `diff-index` — without this,
# a file whose mtime/ctime changed but whose content matches HEAD can
# falsely register as "dirty" (git status auto-refreshes; diff-index
# does not).
git update-index --refresh >/dev/null || true
git diff-index --quiet HEAD -- \
    || die "working tree has uncommitted changes"
git fetch --quiet origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "local main is not aligned with origin/main — pull or push first"
ok "on main, clean, aligned with origin"

STAGE="preflight: git state (tap)"
step "Checking git state (tap)"
tap git remote get-url origin >/dev/null 2>&1 \
    || die "tap has no 'origin' remote"
TAP_BRANCH="$(tap git rev-parse --abbrev-ref HEAD)"
# Same stale-stat refresh as above, applied to the tap clone.
tap git update-index --refresh >/dev/null || true
tap git diff-index --quiet HEAD -- \
    || die "tap working tree has uncommitted changes"
tap git fetch --quiet origin "$TAP_BRANCH"
[ "$(tap git rev-parse HEAD)" = "$(tap git rev-parse "origin/$TAP_BRANCH")" ] \
    || die "tap $TAP_BRANCH is not aligned with origin/$TAP_BRANCH — pull or push first"
ok "tap on $TAP_BRANCH, clean, aligned with origin"

STAGE="preflight: version + tag"
step "Checking version + tag"
# Matches `let version = "X.Y.Z"` — awk -F'"' splits on double quotes,
# field 2 is the literal. Must stay in sync with the parser in build.sh.
CURRENT_VERSION="$(awk -F'"' '/^let version *=/ {print $2; exit}' Sources/Version.swift)"
[[ "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Sources/Version.swift has no parseable 'version' (got: '$CURRENT_VERSION')"
[ "$NEW_VERSION" != "$CURRENT_VERSION" ] \
    || die "Sources/Version.swift is already at $NEW_VERSION"
# sort -V semver-sorts; -C checks the input is already sorted. Feeding
# NEW,CURRENT and asking "is this sorted?" == "is NEW <= CURRENT?" —
# which is what we want to reject.
if printf '%s\n%s\n' "$NEW_VERSION" "$CURRENT_VERSION" | sort -VC 2>/dev/null; then
    die "new version $NEW_VERSION is not greater than current $CURRENT_VERSION"
fi
! git rev-parse "$TAG" >/dev/null 2>&1 \
    || die "tag $TAG already exists locally"
! git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 \
    || die "tag $TAG already exists on origin"
ok "$CURRENT_VERSION → $NEW_VERSION; tag $TAG is free"

STAGE="preflight: formula shape"
step "Checking in-repo formula shape"
grep -qE '/v[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' "$IN_REPO_FORMULA" \
    || die "$IN_REPO_FORMULA has no recognizable /vX.Y.Z.tar.gz URL pattern"
grep -qE 'sha256 "[^"]+"' "$IN_REPO_FORMULA" \
    || die "$IN_REPO_FORMULA has no recognizable sha256 \"...\" line"
ok "url + sha256 lines found"

# In-repo is authoritative; the tap is a mirror overwritten unconditionally
# by the mirror step. We don't enforce byte-identity here — if they've
# drifted (e.g. from an in-repo-only edit between releases), just note it
# and let the release flow bring them back in sync.
if ! diff -q "$IN_REPO_FORMULA" "$TAP_FORMULA" >/dev/null 2>&1; then
    note "in-repo and tap formulas differ — tap will be overwritten by the mirror step"
fi

STAGE="preflight: interactivity"
if [ $YES -eq 0 ] && [ ! -t 0 ]; then
    die "non-interactive shell — pass --yes to skip confirmation"
fi

# ---------------------------------------------------------------------------
# Plan + confirmation
# ---------------------------------------------------------------------------

cat <<PLAN

${B}Plan${N}
  1. $( [ $SKIP_BUILD -eq 1 ] && echo "(skipped) ")Sanity-build with scripts/build.sh
  2. Bump Sources/Version.swift → commit "houdini $NEW_VERSION" → push main (this repo)
  3. Tag $TAG → push tag (this repo)
  4. Fetch $TARBALL_URL, compute sha256
  5. Rewrite url + sha256 in $IN_REPO_FORMULA
  6. Commit "houdini $NEW_VERSION formula" → push main (this repo)
  7. Mirror to $TAP_FORMULA (byte-identical copy)
  8. Commit "houdini $NEW_VERSION" in tap → push $TAP_BRANCH

PLAN

if [ $YES -eq 0 ]; then
    read -r -p "Type the version ($NEW_VERSION) to confirm: " answer
    [ "$answer" = "$NEW_VERSION" ] || die "aborted"
fi

# ---------------------------------------------------------------------------
# Release steps
# ---------------------------------------------------------------------------

# 1. Sanity build
if [ $SKIP_BUILD -eq 0 ]; then
    STAGE="sanity_build"
    step "Sanity-building"
    run ./scripts/build.sh > /dev/null
    ok "build succeeded"
else
    note "sanity build skipped"
fi

# 2. Bump Sources/Version.swift → commit → push. This is the single
# source of truth; build.sh reads it, the binary embeds it, the
# framework Info.plist gets stamped with it.
STAGE="bumping_version"
step "Bumping Sources/Version.swift"
say "rewrite Sources/Version.swift with version = \"$NEW_VERSION\""
cat > Sources/Version.swift <<SWIFT
// Single source of truth for the version string. Read by build.sh
// (stamped into the framework Info.plist) and release.sh (compared +
// rewritten on bump). Edit this file directly only for a hand-patch;
// normal version bumps go through release.sh.

let version = "$NEW_VERSION"
SWIFT
run git add Sources/Version.swift
run git commit -m "houdini $NEW_VERSION"
ok "committed Sources/Version.swift"

STAGE="pushing_version_commit"
run git push origin main
ok "pushed main"

# 3. Tag → push. Pushing the tag is the point of no return — it
# publishes an immutable tarball at $TARBALL_URL.
STAGE="tagging"
step "Tagging $TAG"
run git tag "$TAG"

STAGE="pushing_tag"
run git push origin "$TAG"
ok "pushed $TAG"

# 4. Fetch tarball → compute sha256
STAGE="computing_sha"
step "Fetching tarball + computing sha256"
TMP_TARBALL="$(run mktemp)"
trap 'rm -f "$TMP_TARBALL"; on_err $LINENO' ERR
run curl --retry 5 --retry-delay 3 --retry-all-errors -fsSL "$TARBALL_URL" -o "$TMP_TARBALL"
# A complete source tarball is ≫1 KiB. Anything smaller means GitHub
# returned an error body or an empty response.
say "wc -c < \"$TMP_TARBALL\" | tr -d '[:space:]'"
TARBALL_BYTES="$(wc -c < "$TMP_TARBALL" | tr -d '[:space:]')"
[ "$TARBALL_BYTES" -ge 1024 ] || die "tarball is suspiciously small ($TARBALL_BYTES bytes)"
say "shasum -a 256 \"$TMP_TARBALL\" | awk '{print \$1}'"
SHA="$(shasum -a 256 "$TMP_TARBALL" | awk '{print $1}')"
run rm -f "$TMP_TARBALL"
trap 'on_err $LINENO' ERR
[[ "$SHA" =~ ^[a-f0-9]{64}$ ]] || die "unexpected sha256 output: '$SHA'"
[ "$SHA" != "$EMPTY_SHA256" ]  || die "tarball hashed to the empty-input SHA — fetch returned nothing"
ok "sha256 = $SHA ($TARBALL_BYTES bytes)"

# 5. Rewrite in-repo formula (authoritative source).
STAGE="rewriting_in_repo_formula"
step "Rewriting in-repo formula"
run sed -i.bak -E \
    -e "s|(/v)[0-9]+\.[0-9]+\.[0-9]+(\.tar\.gz)|\1$NEW_VERSION\2|" \
    -e "s|(sha256 \")[^\"]*(\")|\1$SHA\2|" \
    "$IN_REPO_FORMULA"
run rm "$IN_REPO_FORMULA.bak"
run grep -q "v$NEW_VERSION.tar.gz" "$IN_REPO_FORMULA" || die "url rewrite did not take effect"
run grep -q "sha256 \"$SHA\""      "$IN_REPO_FORMULA" || die "sha256 rewrite did not take effect"
ok "url + sha256 updated in $IN_REPO_FORMULA"

# 6. Commit in-repo formula → push main. Second commit on top of the
# version bump — the tagged tarball can't contain its own sha256, so
# this has to land after the tag rather than inside it.
STAGE="committing_in_repo_formula"
run git add Formula/houdini.rb
run git commit -m "houdini $NEW_VERSION formula"
ok "committed in main"

STAGE="pushing_in_repo_formula_commit"
run git push origin main
ok "pushed main"

# 7. Mirror to tap. Pure cp — no sed in two places, so the tap can't
# diverge from the in-repo copy.
STAGE="mirroring_to_tap"
step "Mirroring formula to tap"
run cp "$IN_REPO_FORMULA" "$TAP_FORMULA"
run diff -q "$IN_REPO_FORMULA" "$TAP_FORMULA" >/dev/null \
    || die "mirror to tap did not take effect"
ok "copied $IN_REPO_FORMULA → $TAP_FORMULA"

# 8. Commit tap formula → push
STAGE="committing_tap_formula"
run tap git add Formula/houdini.rb
run tap git commit -m "houdini $NEW_VERSION"
ok "committed in tap"

STAGE="pushing_tap_formula"
run tap git push origin "$TAP_BRANCH"
ok "pushed $TAP_BRANCH"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

STAGE="done"
printf "\n%shoudini %s released.%s\n" "$B" "$NEW_VERSION" "$N"
printf "    tag:      %s\n" "$TAG"
printf "    tarball:  %s\n" "$TARBALL_URL"
printf "    sha256:   %s\n" "$SHA"
printf "    tap:      %s @ %s\n" "$TAP_DIR" "$TAP_BRANCH"
