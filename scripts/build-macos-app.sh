#!/usr/bin/env bash
# Build Blurt.app — the macOS menu bar dictation app.
#
#   ./scripts/build-macos-app.sh [--release] [--run]
#
# Assembles a .app bundle by hand rather than carrying an .xcodeproj: the whole
# build stays inspectable in one file and runs unattended in CI.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APPDIR="apps/macos"

CONFIG="debug"
RUN=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="release" ;;
    --run) RUN=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# 1. The Rust core, as an XCFramework plus generated Swift bindings.
#
# Always rebuilt, never cached on existence: cargo already no-ops when nothing
# changed, and skipping this step once staged bindings that were missing a field
# added to the core minutes earlier. Stale FFI bindings fail in confusing ways.
echo "==> Building the Rust core"
if [[ "$CONFIG" == "release" ]]; then
  ./scripts/build-xcframework.sh --release
else
  ./scripts/build-xcframework.sh
fi

# 2. Stage them into the SwiftPM package. Both are build outputs and gitignored;
#    they are copied rather than symlinked so `swift build` sees stable paths.
echo "==> Staging core artifacts"
mkdir -p "$APPDIR/Frameworks" "$APPDIR/Sources/BlurtCore"
rm -rf "$APPDIR/Frameworks/BlurtCore.xcframework"
cp -R build/BlurtCore.xcframework "$APPDIR/Frameworks/"
cp build/Sources/blurt_core.swift "$APPDIR/Sources/BlurtCore/"

# 3. Compile.
echo "==> swift build ($CONFIG)"
swift build --package-path "$APPDIR" -c "$CONFIG"

if [[ "${BLURT_SKIP_TESTS:-}" != "1" ]]; then
  echo "==> swift test"
  swift test --package-path "$APPDIR" 2>&1 | tail -3
fi

BIN="$ROOT/$APPDIR/.build/$CONFIG/Blurt"
[[ -x "$BIN" ]] || { echo "build produced no executable at $BIN" >&2; exit 1; }

# 4. Assemble the bundle.
APP="$ROOT/build/Blurt.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Blurt"
cp "$APPDIR/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 5. Sign.
#
# Two things here are load-bearing:
#
#   * The entitlements file. We sign with the hardened runtime, which blocks
#     microphone access outright unless com.apple.security.device.audio-input is
#     granted. Without it the app never prompts and never appears in the
#     Microphone list — a silent failure that looks like broken audio code.
#
#   * A stable identity. macOS ties Accessibility and Microphone grants to the
#     code signature, so an ad-hoc signature (which changes every build) makes
#     the system treat each rebuild as a brand new app and drop your grants.
#     Prefer a real certificate whenever one is available.
if [[ -n "${BLURT_SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$BLURT_SIGN_IDENTITY"
else
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 -oE '"Apple Development: [^"]+"' | tr -d '"' || true)
  IDENTITY="${IDENTITY:--}"
fi

echo "==> Signing as: $IDENTITY"
# No `|| true` fallback: a signing failure must be loud. Silently falling back to
# an unentitled signature is what broke microphone access the first time.
codesign --force --deep \
  --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$APPDIR/Resources/Blurt.entitlements" \
  --timestamp=none \
  "$APP"

echo "==> Verifying entitlements"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - | sed 's/^/    /'

echo
echo "OK  $APP"
if [[ "$IDENTITY" == "-" ]]; then
  echo
  echo "NOTE  Ad-hoc signed: no codesigning certificate was found. macOS will"
  echo "      re-ask for Accessibility and Microphone after every rebuild."
fi

if [[ "$RUN" == "1" ]]; then
  echo "==> Launching"
  open "$APP"
fi
