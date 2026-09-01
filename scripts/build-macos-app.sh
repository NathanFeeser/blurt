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

# Preflight: cargo, before anything spends a minute finding out.
#
# Worth its own check rather than letting rustup fail two scripts deep. The
# common case is not a missing install, it is an install that never made it onto
# PATH: rustup writes ~/.cargo/env and leaves sourcing it to your shell profile,
# and if that line is absent the tools exist but no shell can see them. Those two
# situations have different fixes, and `command not found` distinguishes neither.
if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found on PATH." >&2
  if [[ -f "$HOME/.cargo/env" ]]; then
    echo >&2
    echo "Rust is installed at ~/.cargo but is not on your PATH. Add this to" >&2
    echo "your shell profile (~/.zshenv), then open a new shell:" >&2
    echo >&2
    echo '    . "$HOME/.cargo/env"' >&2
  else
    echo "Install Rust: https://rustup.rs" >&2
  fi
  exit 1
fi

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
#
# A release has to run on Intel too, and `swift build` only ever targets the
# machine it is running on — so a shipped build made the ordinary way is
# arm64-only and dies on launch with "you can't open this application" on
# anything else. BLURT_UNIVERSAL builds both slices and stitches them together.
#
# It compiles each architecture separately rather than using SwiftPM's own
# `--arch arm64 --arch x86_64`, which is the documented way and does not work
# here: resolving the WhisperKit package for two destinations at once fails with
# `duplicate key found: ID(moduleName: "ArgmaxCLI")`. Two builds and a lipo
# produce the same binary without depending on that being fixed.
#
# Off by default, because it doubles the build for no benefit during
# development. release-macos.sh sets it.
if [[ "${BLURT_UNIVERSAL:-}" == "1" ]]; then
  echo "==> swift build ($CONFIG, arm64 + x86_64)"
  swift build --package-path "$APPDIR" -c "$CONFIG" --arch arm64
  swift build --package-path "$APPDIR" -c "$CONFIG" --arch x86_64
else
  echo "==> swift build ($CONFIG)"
  swift build --package-path "$APPDIR" -c "$CONFIG"
fi

if [[ "${BLURT_SKIP_TESTS:-}" != "1" ]]; then
  echo "==> swift test"
  swift test --package-path "$APPDIR" 2>&1 | tail -3
fi

# Passing --arch puts the product under an explicit triple directory instead of
# the host symlink, so the universal path has to name both and merge them.
if [[ "${BLURT_UNIVERSAL:-}" == "1" ]]; then
  BIN="$ROOT/build/Blurt-universal"
  lipo -create -output "$BIN" \
    "$ROOT/$APPDIR/.build/arm64-apple-macosx/$CONFIG/Blurt" \
    "$ROOT/$APPDIR/.build/x86_64-apple-macosx/$CONFIG/Blurt"
else
  BIN="$ROOT/$APPDIR/.build/$CONFIG/Blurt"
fi
[[ -x "$BIN" ]] || { echo "build produced no executable at $BIN" >&2; exit 1; }

# 4. Assemble the bundle.
APP="$ROOT/build/Blurt.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Blurt"
cp "$APPDIR/Resources/Info.plist" "$APP/Contents/Info.plist"

# The icon is committed, not generated here. scripts/make-icon.swift draws it and
# is re-run only when the artwork changes; a build that shells out to a renderer
# to produce an asset that almost never moves is a build with a slower inner loop
# and one more thing to go wrong.
cp "$APPDIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

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

# Notarization requires a secure timestamp from Apple's server, which costs a
# network round trip. Development builds skip it and stay usable offline;
# release-macos.sh sets this before it re-signs for distribution.
TIMESTAMP_FLAG="--timestamp=none"
if [[ "${BLURT_SECURE_TIMESTAMP:-}" == "1" ]]; then
  TIMESTAMP_FLAG="--timestamp"
fi

echo "==> Signing as: $IDENTITY"
# No `|| true` fallback: a signing failure must be loud. Silently falling back to
# an unentitled signature is what broke microphone access the first time.
#
# No --deep either. Everything SwiftPM produces here is statically linked, so
# there is no nested code to recurse into, and Apple has deprecated the flag for
# signing: it applies the same entitlements to every nested binary it finds,
# which is wrong the moment one exists. Sparkle will bring nested code with it;
# release-macos.sh signs inner-out explicitly when that happens.
codesign --force \
  --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$APPDIR/Resources/Blurt.entitlements" \
  $TIMESTAMP_FLAG \
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
  # Quit the instance this bundle is already running, if there is one.
  #
  # `open` on an app that is already running does not relaunch it, it just
  # activates it — and step 1 deleted the bundle that process was launched
  # from, so it keeps running code that is no longer on disk. The result is a
  # build that says OK and a menu bar that is still the previous binary, which
  # is a very expensive way to conclude that your change did nothing.
  #
  # Matched by full path, not by name: an installed Blurt.app is somebody
  # else's process and killing it is not this script's business.
  EXEC="$APP/Contents/MacOS/Blurt"
  if pkill -f "$EXEC" 2>/dev/null; then
    echo "==> Quitting the running instance"
    # SIGTERM, so applicationWillTerminate releases the event taps and the
    # audio device before the replacement goes looking for them. Wait for it
    # to actually go rather than guessing at a sleep.
    for _ in $(seq 1 25); do
      pgrep -f "$EXEC" >/dev/null 2>&1 || break
      sleep 0.2
    done
  fi

  # A Blurt from somewhere else is a different problem, and not one to solve by
  # killing it: two instances both claim the same hotkey, and the one that
  # answers is whichever registered first.
  if pgrep -x Blurt >/dev/null 2>&1; then
    echo
    echo "NOTE  Another Blurt is running from a different location. Two builds"
    echo "      share one hotkey; quit that one or your presses may land there."
  fi

  echo "==> Launching"
  open "$APP"
fi
