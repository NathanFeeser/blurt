#!/usr/bin/env bash
# Compile and run the Swift smoke test against the real Rust static library.
# Requires scripts/build-xcframework.sh to have run first.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PROFILE="${1:-debug}"

BINDINGS="$ROOT/build/Sources/blurt_core.swift"
HEADERS="$ROOT/build/Headers"
LIBDIR="$ROOT/target/aarch64-apple-darwin/$PROFILE"

for path in "$BINDINGS" "$HEADERS/module.modulemap" "$LIBDIR/libblurt_core.a"; do
  if [[ ! -e "$path" ]]; then
    echo "missing $path — run ./scripts/build-xcframework.sh first" >&2
    exit 1
  fi
done

OUT="$ROOT/build/smoketest"
# Link the .a by full path, not -lblurt_core: the target dir also contains a
# .dylib and the linker prefers it, which would silently test a different
# artifact from the one the xcframework ships.
echo "==> Compiling smoke test"
swiftc -O \
  -o "$OUT" \
  "$BINDINGS" \
  "$ROOT/swift/SmokeTest/main.swift" \
  -I "$HEADERS" \
  "$LIBDIR/libblurt_core.a" \
  -framework Security \
  -framework CoreFoundation \
  -framework SystemConfiguration \
  -suppress-warnings

echo "==> Running"
echo
"$OUT"
