#!/bin/bash
# build.sh — compile MediaRemoteAdapter.framework from vendored Obj-C
# sources, then the houdini Swift binary.
#
# Usage:
#   ./scripts/build.sh                       # dev build at project root
#   PREFIX=/some/prefix ./scripts/build.sh   # staged install layout
#
# Env:
#   PREFIX   install prefix. Unset = dev build at project root.
#            Set by the Homebrew formula to stage under the keg.

set -Eeuo pipefail
shopt -s nullglob

SCRIPT_NAME="$(basename "$0")"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

VENDOR="vendor/mediaremote-adapter"
FRAMEWORK_NAME="MediaRemoteAdapter"
FRAMEWORK="${FRAMEWORK_NAME}.framework"
BINARY="houdini"

# Deployment floor + Swift compiler floor. MIN_MACOS matches the
# Homebrew formula's `depends_on macos:`; MIN_SWIFT matches the
# `-swift-version 6` flag passed to swiftc below (Swift 6 language mode
# requires compiler ≥ 6.0). Package.swift's swift-tools-version is
# independent — it gates manifest APIs, not the source-code floor.
MIN_MACOS="15.0"
MIN_SWIFT="6.0"
HOST_ARCH="$(uname -m)"

# Optional install prefix. Unset = flat dev layout at $PROJECT_ROOT.
# When set (e.g. by the Homebrew formula), outputs are staged into:
#   $PREFIX/bin/houdini
#   $PREFIX/libexec/houdini/MediaRemoteAdapter.framework
#   $PREFIX/libexec/houdini/vendor/
PREFIX="${PREFIX:-$PROJECT_ROOT}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    B="$(tput bold)"; G="$(tput setaf 2)"; R="$(tput setaf 1)"; N="$(tput sgr0)"
else
    B=""; G=""; R=""; N=""
fi

step() { printf "%s==>%s %s\n" "$B" "$N" "$1"; }
ok()   { printf "    %s✓%s %s\n" "$G" "$N" "$1"; }
info() { printf "    %s\n" "$1"; }
kv()   { printf "    %-11s %s\n" "$1:" "$2"; }
die()  { printf "%s%s: %s%s\n" "$R$B" "$SCRIPT_NAME" "$1" "$N" >&2; exit 1; }

# Human-readable size of a file or directory (e.g. "1.2M"). Works on
# BSD (macOS) and GNU coreutils.
hsize() {
    if [ -e "$1" ]; then
        du -sh "$1" 2>/dev/null | awk '{print $1}'
    else
        printf '?'
    fi
}

trap 'die "failed near line $LINENO"' ERR

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

step "Checking prerequisites"
for tool in swiftc clang codesign perl; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH"
done
[ -d "$VENDOR" ]          || die "$VENDOR/ not found — run from the project root"
[ -d Sources ]            || die "Sources/ not found — wrong working directory?"
[ -f Sources/main.swift ] || die "Sources/main.swift not found"

# `.swift-version` (if present) pins the dev toolchain for swiftly users
# but isn't required — the build only enforces a minimum.
SWIFT_VERSION_LINE="$(swiftc --version 2>/dev/null | head -1)"
ACTUAL_SWIFT="$(printf '%s\n' "$SWIFT_VERSION_LINE" \
    | grep -oE 'Swift version [0-9]+\.[0-9]+(\.[0-9]+)?' \
    | awk '{print $3}')"
[ -n "$ACTUAL_SWIFT" ] || die "could not parse Swift version from: $SWIFT_VERSION_LINE"
if ! printf '%s\n%s\n' "$MIN_SWIFT" "$ACTUAL_SWIFT" | sort -C -V; then
    die "swiftc is Swift $ACTUAL_SWIFT but $MIN_SWIFT or newer is required — install via swiftly/Xcode-select"
fi
ok "toolchain: swiftc, clang, codesign, perl  (Swift $ACTUAL_SWIFT ≥ $MIN_SWIFT)"

# ---------------------------------------------------------------------------
# Version — read from Sources/Version.swift (the single source of truth)
# ---------------------------------------------------------------------------

[ -f Sources/Version.swift ] || die "Sources/Version.swift missing"
# Parse `let version = "X.Y.Z"` — first quoted string wins. Same parser
# as scripts/release.sh; keep them in sync.
VERSION="$(awk -F'"' '/^let version *=/ {print $2; exit}' Sources/Version.swift)"
[ -n "$VERSION" ]  || die "could not parse 'version' from Sources/Version.swift"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "'version' in Sources/Version.swift is malformed: '$VERSION'"
step "Version"
ok "version = \"$VERSION\" (from Sources/Version.swift)"

# ---------------------------------------------------------------------------
# Configuration report — what we're about to build
# ---------------------------------------------------------------------------

SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || echo unknown)"

step "Build configuration"
kv "version"   "$VERSION"
kv "host arch" "$HOST_ARCH"
kv "SDK"       "macOS $SDK_VERSION"
kv "target"    "macOS $MIN_MACOS+"
kv "Swift"     "$ACTUAL_SWIFT (min $MIN_SWIFT)"
if [ "$PREFIX" = "$PROJECT_ROOT" ]; then
    kv "layout" "dev build (flat, at project root)"
else
    kv "layout" "install → $PREFIX"
fi

# ---------------------------------------------------------------------------
# Enumerate Obj-C sources for the framework
# ---------------------------------------------------------------------------

step "Enumerating framework sources"
SOURCES=()
for f in "$VENDOR"/src/adapter/*.m; do
    case "$f" in
        */test.m) ;;   # excluded — depends on test-client target we don't vendor
        *) SOURCES+=("$f") ;;
    esac
done
SOURCES+=("$VENDOR"/src/private/*.m "$VENDOR"/src/utility/*.m)
[ ${#SOURCES[@]} -gt 0 ] || die "no .m sources found under $VENDOR/src"
ok "${#SOURCES[@]} .m sources (test.m excluded)"

# ---------------------------------------------------------------------------
# Clean previous outputs (project root only — staged outputs under
# $PREFIX are cleaned later, just before staging)
# ---------------------------------------------------------------------------

step "Cleaning previous build outputs"
rm -rf "$FRAMEWORK" "$BINARY"
ok "removed ./$FRAMEWORK, ./$BINARY"

# ---------------------------------------------------------------------------
# Framework — compile → lay out → sign
# ---------------------------------------------------------------------------

step "Compiling $FRAMEWORK"
info "archs: arm64, x86_64 — target: macOS $MIN_MACOS+"
info "libs:  Foundation, AppKit, JavaScriptCore, UniformTypeIdentifiers"
mkdir -p "$FRAMEWORK/Versions/A/Resources" "$FRAMEWORK/Versions/A/Headers"
clang \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min="$MIN_MACOS" \
    -fobjc-arc -fvisibility=default \
    -dynamiclib \
    -framework Foundation -framework AppKit \
    -framework JavaScriptCore -framework UniformTypeIdentifiers \
    -I"$VENDOR/include" -I"$VENDOR/src" \
    -install_name "@rpath/$FRAMEWORK/Versions/A/$FRAMEWORK_NAME" \
    -o "$FRAMEWORK/Versions/A/$FRAMEWORK_NAME" \
    "${SOURCES[@]}"
ok "linked $FRAMEWORK_NAME ($(hsize "$FRAMEWORK/Versions/A/$FRAMEWORK_NAME"), universal)"

step "Laying out framework structure"
cp "$VENDOR/include/$FRAMEWORK_NAME.h" "$FRAMEWORK/Versions/A/Headers/"
cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$FRAMEWORK_NAME</string>
    <key>CFBundleIdentifier</key><string>com.github.mgxv.houdini.$FRAMEWORK_NAME</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$FRAMEWORK_NAME</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
</dict>
</plist>
PLIST
(cd "$FRAMEWORK/Versions" && ln -sfn A Current)
(cd "$FRAMEWORK" \
    && ln -sfn "Versions/Current/$FRAMEWORK_NAME" "$FRAMEWORK_NAME" \
    && ln -sfn "Versions/Current/Resources" "Resources" \
    && ln -sfn "Versions/Current/Headers" "Headers")
ok "Info.plist (v$VERSION) + Versions/Current + top-level symlinks"

step "Ad-hoc code-signing $FRAMEWORK"
codesign --force --sign - "$FRAMEWORK"
ok "signed (ad-hoc)"

# ---------------------------------------------------------------------------
# Binary — compile Swift sources
# ---------------------------------------------------------------------------

step "Compiling $BINARY"
SWIFT_SOURCES=(Sources/*.swift)
[ ${#SWIFT_SOURCES[@]} -gt 0 ] || die "no .swift sources found under Sources/"
info "target: ${HOST_ARCH}-apple-macos${MIN_MACOS} — optimization: -O"
info "libs:   Cocoa"
info "Swift:  language mode 6 (strict concurrency)"
swiftc -O \
    -swift-version 6 \
    -target "${HOST_ARCH}-apple-macos${MIN_MACOS}" \
    -o "$BINARY" "${SWIFT_SOURCES[@]}" \
    -framework Cocoa
ok "linked $BINARY ($(hsize "$BINARY"), ${#SWIFT_SOURCES[@]} .swift files)"

# ---------------------------------------------------------------------------
# Install (if PREFIX is set — triggered by Homebrew)
# ---------------------------------------------------------------------------

if [ "$PREFIX" != "$PROJECT_ROOT" ]; then
    step "Installing to $PREFIX"
    BIN_DIR="$PREFIX/bin"
    LIBEXEC_DIR="$PREFIX/libexec/houdini"
    mkdir -p "$BIN_DIR" "$LIBEXEC_DIR"
    rm -rf "$LIBEXEC_DIR/$FRAMEWORK" "$LIBEXEC_DIR/vendor" "$BIN_DIR/$BINARY"
    cp -R "$FRAMEWORK" "$LIBEXEC_DIR/"   # cp -R preserves Versions/Current symlinks
    cp -R vendor "$LIBEXEC_DIR/"
    mv "$BINARY" "$BIN_DIR/"
    rm -rf "$FRAMEWORK"                  # framework was copied, not moved
    ok "staged under $PREFIX"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf "\n%sBuild complete.%s (%ds)\n" "$B" "$N" "$SECONDS"
if [ "$PREFIX" = "$PROJECT_ROOT" ]; then
    printf "    %-40s  %s\n" "./$FRAMEWORK" "$(hsize "./$FRAMEWORK")"
    printf "    %-40s  %s\n" "./$BINARY"    "$(hsize "./$BINARY")"
else
    printf "    %-60s  %s\n" "$PREFIX/bin/$BINARY"                 "$(hsize "$PREFIX/bin/$BINARY")"
    printf "    %-60s  %s\n" "$PREFIX/libexec/houdini/$FRAMEWORK"  "$(hsize "$PREFIX/libexec/houdini/$FRAMEWORK")"
    printf "    %-60s  %s\n" "$PREFIX/libexec/houdini/vendor/"     "$(hsize "$PREFIX/libexec/houdini/vendor")"
fi
