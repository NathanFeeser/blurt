#!/usr/bin/env bash
# Rehearse a Sparkle update end to end, without publishing anything.
#
#   ./scripts/rehearse-update.sh
#
# Builds a "future" version of whatever is in build/Blurt.app, signs an appcast
# for it, serves both from localhost, and launches the current build pointed at
# that feed. Then you do the one part that cannot be scripted: open the menu,
# choose Check for Updates…, and watch it find, download, verify and install
# the future version, then relaunch as it.
#
# This is the only way to exercise the update path before a release exists.
# Sparkle 2 stopped honouring a feed URL in user defaults, so the app reads
# BLURT_UPDATE_FEED from its environment instead — see Updates.swift — and that
# override is the whole trick here.
#
# Needs build/Blurt.app from ./scripts/build-macos-app.sh, and the Sparkle key
# in the keychain that release-macos.sh also uses.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APPDIR="apps/macos"
APP="$ROOT/build/Blurt.app"
PORT="${BLURT_REHEARSAL_PORT:-8000}"
SPARKLE_BIN="$APPDIR/.build/artifacts/sparkle/Sparkle/bin"

[[ -d "$APP" ]] || { echo "no $APP — run ./scripts/build-macos-app.sh first" >&2; exit 1; }
[[ -x "$SPARKLE_BIN/generate_appcast" ]] || {
  echo "Sparkle tools missing; run: swift package --package-path $APPDIR resolve" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is needed to serve the feed" >&2; exit 1; }

# Sparkle refuses an update whose code signature does not match the running
# app's, so the future copy must be signed by the same identity — whichever one
# built the app in build/, which is not necessarily the one this script would
# pick on its own.
# Two verbosity levels are needed before codesign prints Authority lines, and
# the output is captured before it is searched: a grep with no match in a
# pipeline under pipefail would end the script inside the assignment, before
# the check below could say why.
SIGNATURE=$(codesign -d --verbose=2 "$APP" 2>&1 || true)
IDENTITY=$(grep -m1 '^Authority=' <<<"$SIGNATURE" | cut -d= -f2- || true)
[[ -n "$IDENTITY" ]] || {
  echo "could not read the signing identity of $APP; is it signed?" >&2; exit 1; }

CURRENT_BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
CURRENT_VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
FUTURE_BUILD=$((CURRENT_BUILD + 1000))
FUTURE_VERSION="$CURRENT_VERSION-rehearsal"

echo "==> Current:  $CURRENT_VERSION ($CURRENT_BUILD), signed by $IDENTITY"
echo "==> Future:   $FUTURE_VERSION ($FUTURE_BUILD)"

FEED=$(mktemp -d)
trap 'kill "${SERVER_PID:-}" 2>/dev/null || true; rm -rf "$FEED"' EXIT

# The future app is the current one with a bigger build number. Only the outer
# signature is redone: nothing inside changed, and the nested Sparkle code is
# already signed by the same identity.
FUTURE_APP="$FEED/Blurt.app"
ditto "$APP" "$FUTURE_APP"
plutil -replace CFBundleVersion -string "$FUTURE_BUILD" "$FUTURE_APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$FUTURE_VERSION" "$FUTURE_APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" --options runtime \
  --entitlements "$APPDIR/Resources/Blurt.entitlements" "$FUTURE_APP"

ARCHIVES="$FEED/archives"
mkdir -p "$ARCHIVES"
ditto -c -k --keepParent "$FUTURE_APP" "$ARCHIVES/Blurt-$FUTURE_VERSION.zip"
rm -rf "$FUTURE_APP"
cat > "$ARCHIVES/Blurt-$FUTURE_VERSION.html" <<EOF
<h2>Blurt $FUTURE_VERSION</h2>
<p>A rehearsal. If you can read this inside the update window, release notes work too.</p>
EOF

echo "==> Signing the appcast (the keychain may ask once)"
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "http://localhost:$PORT/" \
  -o "$ARCHIVES/appcast.xml" \
  "$ARCHIVES" >/dev/null

# Requests are logged, so the rehearsal leaves evidence: a GET for the appcast
# proves the app reached the feed, a GET for the zip proves it went for the
# update.
SERVER_LOG="$ROOT/build/rehearsal-server.log"
: > "$SERVER_LOG"
echo "==> Serving the feed on http://localhost:$PORT (requests: $SERVER_LOG)"
( cd "$ARCHIVES" && python3 -m http.server "$PORT" --bind 127.0.0.1 >>"$SERVER_LOG" 2>&1 ) &
SERVER_PID=$!
sleep 1
kill -0 "$SERVER_PID" 2>/dev/null || { echo "could not start the server on port $PORT" >&2; exit 1; }

# The instance that is about to be updated must be launched with the override,
# so any copy already running is not the one being tested.
if pgrep -x Blurt >/dev/null 2>&1; then
  echo "==> Quitting the running Blurt"
  pkill -x Blurt || true
  for _ in $(seq 1 25); do pgrep -x Blurt >/dev/null 2>&1 || break; sleep 0.2; done
fi

echo "==> Launching $CURRENT_VERSION against the rehearsal feed"
BLURT_UPDATE_FEED="http://localhost:$PORT/appcast.xml" "$APP/Contents/MacOS/Blurt" \
  >/dev/null 2>&1 &

cat <<EOF

Now, from the menu bar icon: Check for Updates…

  Expect:  "Blurt $FUTURE_VERSION is now available — you have $CURRENT_VERSION"
  Then:    Install Update, and it relaunches as $FUTURE_VERSION
  Verify:  About Blurt shows $FUTURE_VERSION ($FUTURE_BUILD)

Afterwards build/Blurt.app IS the future version; ./scripts/build-macos-app.sh
puts it back. This script keeps serving the feed until you press Ctrl-C.
EOF
wait "$SERVER_PID"
