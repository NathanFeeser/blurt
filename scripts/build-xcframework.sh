#!/usr/bin/env bash
# Build blurt-core as an XCFramework plus Swift bindings for the macOS and
# iOS shells.
#
#   ./scripts/build-xcframework.sh [--release]
#
# Output:
#   build/BlurtCore.xcframework   <- drag into Xcode, or reference from SwiftPM
#   build/Sources/                   <- generated Swift bindings (blurt_core.swift)
#
# This script is the load-bearing half of the "Rust core" decision. If it is not
# green, the decision is not real — see the risk table in docs/PLAN.md.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CRATE="blurt-core"
LIB="libblurt_core.a"
FRAMEWORK="BlurtCore"

# macOS ships bash 3.2, where expanding an empty array under `set -u` is an
# error. A plain string keeps this portable to the system shell.
PROFILE="debug"
CARGO_FLAGS=""
if [[ "${1:-}" == "--release" ]]; then
  PROFILE="release"
  CARGO_FLAGS="--release"
fi

# Without these, cargo links Apple targets against ancient defaults (iOS 10.0)
# and aws-lc-sys fails on ___chkstk_darwin, which only exists from iOS 12.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

MAC_TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
IOS_TARGET=aarch64-apple-ios
SIM_TARGETS=(aarch64-apple-ios-sim x86_64-apple-ios)
ALL_TARGETS=("${MAC_TARGETS[@]}" "$IOS_TARGET" "${SIM_TARGETS[@]}")

echo "==> Ensuring targets are installed"
for t in "${ALL_TARGETS[@]}"; do
  rustup target add "$t" >/dev/null
done

echo "==> Building $CRATE for ${#ALL_TARGETS[@]} targets ($PROFILE)"
for t in "${ALL_TARGETS[@]}"; do
  echo "    - $t"
  cargo build -p "$CRATE" --target "$t" $CARGO_FLAGS
done

BUILD="$ROOT/build"
rm -rf "$BUILD"
mkdir -p "$BUILD/Sources" "$BUILD/Headers" "$BUILD/universal/macos" "$BUILD/universal/sim"

echo "==> Generating Swift bindings"
# uniffi reads the metadata baked into a built library, so the bindings can
# never drift from the Rust that produced them.
cargo run -p "$CRATE" --bin uniffi-bindgen --features uniffi-cli -- \
  generate \
  --library "$ROOT/target/aarch64-apple-darwin/$PROFILE/libblurt_core.dylib" \
  --language swift \
  --out-dir "$BUILD/Sources" \
  --no-format

# uniffi emits <name>FFI.modulemap; Xcode wants a module.modulemap next to the
# headers inside each framework slice.
mv "$BUILD/Sources"/*.h "$BUILD/Headers/"
cat "$BUILD/Sources"/*.modulemap > "$BUILD/Headers/module.modulemap"
rm -f "$BUILD/Sources"/*.modulemap

echo "==> Creating universal binaries"
lipo -create -output "$BUILD/universal/macos/$LIB" \
  "$ROOT/target/aarch64-apple-darwin/$PROFILE/$LIB" \
  "$ROOT/target/x86_64-apple-darwin/$PROFILE/$LIB"
lipo -create -output "$BUILD/universal/sim/$LIB" \
  "$ROOT/target/aarch64-apple-ios-sim/$PROFILE/$LIB" \
  "$ROOT/target/x86_64-apple-ios/$PROFILE/$LIB"

echo "==> Assembling $FRAMEWORK.xcframework"
xcodebuild -create-xcframework \
  -library "$BUILD/universal/macos/$LIB" -headers "$BUILD/Headers" \
  -library "$ROOT/target/$IOS_TARGET/$PROFILE/$LIB" -headers "$BUILD/Headers" \
  -library "$BUILD/universal/sim/$LIB" -headers "$BUILD/Headers" \
  -output "$BUILD/$FRAMEWORK.xcframework" >/dev/null

echo
echo "OK  $BUILD/$FRAMEWORK.xcframework"
echo "OK  $BUILD/Sources/$(ls "$BUILD/Sources" | head -1)"
