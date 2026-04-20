#!/bin/bash
# Builds MediaRemoteAdapter.framework from vendored source, then houdini.

set -euo pipefail
shopt -s nullglob

SCRIPT_NAME="$(basename "$0")"
PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_ROOT"

VENDOR="vendor/mediaremote-adapter"
FRAMEWORK_NAME="MediaRemoteAdapter"
FRAMEWORK="${FRAMEWORK_NAME}.framework"
BINARY="houdini"

# Deployment floor. Keep in sync with the Homebrew formula's
# `depends_on macos:` and any README claims.
MIN_MACOS="15.0"
HOST_ARCH="$(uname -m)"

# Optional install prefix. When unset, the build produces a flat dev
# layout at $PROJECT_ROOT. When set (e.g. by the Homebrew formula),
# outputs are staged into:
#   $PREFIX/bin/houdini
#   $PREFIX/libexec/houdini/MediaRemoteAdapter.framework
#   $PREFIX/libexec/houdini/vendor/
PREFIX="${PREFIX:-$PROJECT_ROOT}"

if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    B="$(tput bold)"; G="$(tput setaf 2)"; R="$(tput setaf 1)"; N="$(tput sgr0)"
else
    B=""; G=""; R=""; N=""
fi

step() { printf "%s==>%s %s\n" "$B" "$N" "$1"; }
ok()   { printf "    %s✓%s %s\n" "$G" "$N" "$1"; }
die()  { printf "%s%s: %s%s\n" "$R$B" "$SCRIPT_NAME" "$1" "$N" >&2; exit 1; }

trap 'die "failed near line $LINENO"' ERR

step "Checking prerequisites"
for tool in swiftc clang codesign perl; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH"
done
[ -d "$VENDOR" ] || die "$VENDOR/ not found — run from the project root"
[ -d Sources ] || die "Sources/ not found — wrong working directory?"
[ -f Sources/main.swift ] || die "Sources/main.swift not found"

# `.swift-version` (if present) pins the dev toolchain for swiftly users;
# it's not required. The build only enforces a minimum Swift version.
MIN_SWIFT="5.10"
SWIFT_VERSION_LINE="$(swiftc --version 2>/dev/null | head -1)"
ACTUAL_SWIFT="$(printf '%s\n' "$SWIFT_VERSION_LINE" \
    | grep -oE 'Swift version [0-9]+\.[0-9]+(\.[0-9]+)?' \
    | awk '{print $3}')"
[ -n "$ACTUAL_SWIFT" ] || die "could not parse Swift version from: $SWIFT_VERSION_LINE"
if ! printf '%s\n%s\n' "$MIN_SWIFT" "$ACTUAL_SWIFT" | sort -C -V; then
    die "swiftc is Swift $ACTUAL_SWIFT but $MIN_SWIFT or newer is required — install via swiftly/Xcode-select"
fi
ok "swiftc, clang, codesign, perl available (Swift $ACTUAL_SWIFT ≥ $MIN_SWIFT)"

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
ok "${#SOURCES[@]} source files (test.m excluded)"

step "Cleaning previous build outputs"
rm -rf "$FRAMEWORK" "$BINARY"

step "Compiling $FRAMEWORK (arm64 + x86_64, macOS $MIN_MACOS+)"
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
ok "linked $FRAMEWORK_NAME (universal)"

step "Laying out framework structure"
cp "$VENDOR/include/$FRAMEWORK_NAME.h" "$FRAMEWORK/Versions/A/Headers/"
cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$FRAMEWORK_NAME</string>
    <key>CFBundleIdentifier</key><string>com.houdini.$FRAMEWORK_NAME</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$FRAMEWORK_NAME</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
</dict>
</plist>
PLIST
(cd "$FRAMEWORK/Versions" && ln -sfn A Current)
(cd "$FRAMEWORK" \
    && ln -sfn "Versions/Current/$FRAMEWORK_NAME" "$FRAMEWORK_NAME" \
    && ln -sfn "Versions/Current/Resources" "Resources" \
    && ln -sfn "Versions/Current/Headers" "Headers")
ok "Info.plist + Versions/Current symlinks"

step "Ad-hoc code-signing $FRAMEWORK"
codesign --force --sign - "$FRAMEWORK"
ok "signed"

step "Compiling $BINARY ($HOST_ARCH, macOS $MIN_MACOS+)"
SWIFT_SOURCES=(Sources/*.swift)
[ ${#SWIFT_SOURCES[@]} -gt 0 ] || die "no .swift sources found under Sources/"
swiftc -O \
    -target "${HOST_ARCH}-apple-macos${MIN_MACOS}" \
    -o "$BINARY" "${SWIFT_SOURCES[@]}" \
    -framework Cocoa -framework ApplicationServices
ok "linked $BINARY (${#SWIFT_SOURCES[@]} source files)"

if [ "$PREFIX" != "$PROJECT_ROOT" ]; then
    step "Installing to $PREFIX"
    BIN_DIR="$PREFIX/bin"
    LIBEXEC_DIR="$PREFIX/libexec/houdini"
    mkdir -p "$BIN_DIR" "$LIBEXEC_DIR"
    # Wipe any stale artifacts from a previous install at this prefix.
    rm -rf "$LIBEXEC_DIR/$FRAMEWORK" "$LIBEXEC_DIR/vendor" "$BIN_DIR/$BINARY"
    # `cp -R` preserves the framework's internal Versions/Current symlinks.
    cp -R "$FRAMEWORK" "$LIBEXEC_DIR/"
    cp -R vendor "$LIBEXEC_DIR/"
    mv "$BINARY" "$BIN_DIR/"
    # Framework was copied, not moved — clean the staging location so the
    # project root doesn't end up with a duplicate copy.
    rm -rf "$FRAMEWORK"
    ok "installed under $PREFIX"
fi

printf "\n%sBuild complete.%s\n" "$B" "$N"
if [ "$PREFIX" = "$PROJECT_ROOT" ]; then
    printf "    ./%s\n" "$FRAMEWORK"
    printf "    ./%s\n" "$BINARY"
else
    printf "    %s/bin/%s\n" "$PREFIX" "$BINARY"
    printf "    %s/libexec/houdini/%s\n" "$PREFIX" "$FRAMEWORK"
    printf "    %s/libexec/houdini/vendor/\n" "$PREFIX"
fi
