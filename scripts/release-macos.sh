#!/usr/bin/env bash
# Build, sign, notarize, and package Blurt for direct download.
#
#   ./scripts/release-macos.sh [--version X.Y.Z] [--skip-notarize] [--publish]
#
# Output:
#   build/release/Blurt-X.Y.Z.dmg   <- what people download
#   build/release/Blurt-X.Y.Z.zip   <- what Sparkle downloads
#   build/release/appcast.xml       <- what installed copies poll
#
# With --publish it also tags the commit and creates the GitHub release, which
# is the step that actually puts the .dmg somewhere a stranger can reach.
#
# This is deliberately separate from build-macos-app.sh. That script is the
# development loop and must stay fast and offline; this one talks to Apple's
# notary service and is expected to take minutes.
#
# Prerequisites, both one-time:
#
#   1. A "Developer ID Application" certificate in the login keychain. Not
#      "Apple Development" (which only runs on registered development machines)
#      and not "Apple Distribution" (which is App Store only, a store Blurt can
#      never ship on because Accessibility requires an unsandboxed process).
#      Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#
#   2. notarytool credentials stored in a keychain profile:
#      xcrun notarytool store-credentials blurt-notary \
#        --key AuthKey_XXXXXX.p8 --key-id XXXXXX --issuer <issuer-uuid>
#
#   3. A Sparkle signing key in the keychain, matching SUPublicEDKey in
#      Info.plist. Generated once with the package's generate_keys tool, and
#      backed up — every installed copy checks updates against it, so losing
#      it strands them all on whatever version they have.
#
#   4. For --publish only: the GitHub CLI, authenticated. `brew install gh`
#      then `gh auth login`.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
APPDIR="apps/macos"
PLIST="$APPDIR/Resources/Info.plist"
NOTARY_PROFILE="${BLURT_NOTARY_PROFILE:-blurt-notary}"

VERSION=""
SKIP_NOTARIZE=0
PUBLISH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    --publish) PUBLISH=1; shift ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  VERSION=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "version must look like X.Y.Z, got: $VERSION" >&2; exit 1
}

# CFBundleVersion has to increase on every build Apple ever sees, and it is what
# Sparkle compares to decide an update exists. Commit count is monotonic, needs
# no state file, and is derivable from any checkout.
BUILD_NUMBER=$(git rev-list --count HEAD)

# ---------------------------------------------------------------------------
# Preflight. Every one of these failures is cheaper to hit now than after a
# five-minute build, and the notary service failures in particular are opaque
# enough that catching them here is worth the duplication.
# ---------------------------------------------------------------------------
echo "==> Preflight"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -m1 -oE '"Developer ID Application: [^"]+"' | tr -d '"' || true)
if [[ -z "$IDENTITY" ]]; then
  cat >&2 <<'EOF'
No "Developer ID Application" certificate found in the keychain.

This is the only identity Gatekeeper accepts for an app distributed outside the
App Store. Create one in about a minute:

  Xcode > Settings > Accounts > (your team) > Manage Certificates
    > + > Developer ID Application

Then re-run this script. `security find-identity -v -p codesigning` should list
it. Note that "Apple Development" and "Apple Distribution" certificates, which
you may already have, will not work here: the first is limited to registered
development machines, and the second only signs App Store submissions.
EOF
  exit 1
fi
echo "    identity:  $IDENTITY"

if [[ "$SKIP_NOTARIZE" == "0" ]]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF
No usable notarytool credentials under keychain profile "$NOTARY_PROFILE".

Create an App Store Connect API key (Users and Access > Integrations >
App Store Connect API, Developer role), download the .p8 once, then:

  xcrun notarytool store-credentials $NOTARY_PROFILE \\
    --key ~/Downloads/AuthKey_XXXXXX.p8 --key-id XXXXXX --issuer <issuer-uuid>

Or pass --skip-notarize to produce an unnotarized build for local testing. That
build will run on this Mac and nowhere else without a Gatekeeper override.
EOF
    exit 1
  fi
  echo "    notary:    $NOTARY_PROFILE"
else
  echo "    notary:    SKIPPED (local build only)"
fi

TAG="v$VERSION"

# Baked into the appcast as the download location, so it is needed whether or
# not this run publishes. From the git remote rather than gh: a local build
# should not need GitHub's CLI just to know where releases live.
REPO=$(git remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
[[ "$REPO" == */* ]] || {
  echo "could not derive owner/repo from origin: $(git remote get-url origin)" >&2; exit 1; }

# Publishing preflight runs here, with the rest, rather than at the end where the
# work happens: every one of these is a five-minute build and a notarization
# round trip away from being discovered otherwise.
if [[ "$PUBLISH" == "1" ]]; then
  if [[ "$SKIP_NOTARIZE" == "1" ]]; then
    echo "--publish with --skip-notarize would ship a build that runs on no Mac but this one." >&2
    exit 1
  fi

  command -v gh >/dev/null 2>&1 || {
    echo "gh not found. Install it with: brew install gh" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || {
    echo "gh is not authenticated. Run: gh auth login" >&2; exit 1; }

  # A release names a commit that anyone can check out, so the tree has to be
  # clean — untracked files included, since SwiftPM compiles any .swift sitting
  # in a source directory whether git knows about it or not.
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean. Commit or stash before publishing:" >&2
    git status --short >&2
    exit 1
  fi

  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "Tag $TAG already exists. Bump --version, or delete the tag." >&2
    exit 1
  fi

  # BUILD_NUMBER is the commit count, so a release built from an unpushed commit
  # gets a build number nobody else can reproduce.
  git fetch --quiet origin 2>/dev/null || true
  if ! git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    echo "HEAD is not on origin/main. Push your commits before publishing." >&2
    exit 1
  fi

  echo "    publish:   $TAG to $REPO"
fi

# The release before this one, for the changes link. Resolved now, before the
# new tag exists, so the newest reachable tag is the previous release.
PREV=$(git describe --tags --abbrev=0 2>/dev/null || true)
[[ "$PREV" != "$TAG" ]] || PREV=""

SPARKLE_BIN="$APPDIR/.build/artifacts/sparkle/Sparkle/bin"
if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  echo "Sparkle's tools are missing. Run: swift package --package-path $APPDIR resolve" >&2
  exit 1
fi
SPARKLE_KEY=$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null \
  | grep -oE '[A-Za-z0-9+/]{40,}={0,2}' | head -1 || true)
if [[ -z "$SPARKLE_KEY" ]]; then
  cat >&2 <<EOF
No Sparkle signing key in the keychain. Generate one, once, and back it up:

  $SPARKLE_BIN/generate_keys
  $SPARKLE_BIN/generate_keys -x ~/somewhere-safe/blurt-sparkle.key

Then put the SUPublicEDKey it prints into $PLIST.
EOF
  exit 1
fi
PLIST_KEY=$(plutil -extract SUPublicEDKey raw "$PLIST" 2>/dev/null || true)
if [[ "$SPARKLE_KEY" != "$PLIST_KEY" ]]; then
  cat >&2 <<EOF
The Sparkle key in the keychain does not match SUPublicEDKey in $PLIST.

  keychain:    $SPARKLE_KEY
  Info.plist:  ${PLIST_KEY:-(missing)}

Every installed copy verifies downloads against the key it shipped with. An
update signed with any other key is refused as tampered — by every user, with
no way back short of a manual reinstall. Not publishing this.
EOF
  exit 1
fi
echo "    sparkle:   key matches Info.plist"

echo "    version:   $VERSION ($BUILD_NUMBER)"

# ---------------------------------------------------------------------------
# Build. Release configuration, tests included: a release that skips its own
# test suite is how a broken build gets a version number.
# ---------------------------------------------------------------------------
echo
echo "==> Building"
# BLURT_BUNDLE_ID: without it the build script stamps the development id, and
# Sparkle refuses an update whose bundle id differs from the running app's —
# a ".dev" release would be rejected by every installed copy, silently.
BLURT_SIGN_IDENTITY="$IDENTITY" BLURT_SECURE_TIMESTAMP=1 BLURT_UNIVERSAL=1 \
  BLURT_BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$PLIST")" \
  ./scripts/build-macos-app.sh --release

APP="$ROOT/build/Blurt.app"
[[ -d "$APP" ]] || { echo "expected $APP" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Stamp the version and re-sign.
#
# The signature covers Info.plist, so editing the version has to happen before
# signing — which means re-signing here rather than teaching the build script
# about release versioning. codesign --force replacing its own signature is
# routine, and it keeps the development path free of release concerns.
# ---------------------------------------------------------------------------
echo
echo "==> Stamping $VERSION ($BUILD_NUMBER)"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

echo "==> Re-signing"
codesign --force \
  --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$APPDIR/Resources/Blurt.entitlements" \
  --timestamp \
  "$APP"

# --strict catches things a plain verify will not, and is closer to what the
# notary service itself runs.
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Identity"
BUILT_ID=$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")
WANT_ID=$(plutil -extract CFBundleIdentifier raw "$PLIST")
echo "    $BUILT_ID"
[[ "$BUILT_ID" == "$WANT_ID" ]] || {
  echo "release is stamped $BUILT_ID, not $WANT_ID — every installed copy would refuse it" >&2
  exit 1; }

echo "==> Architectures"
lipo -info "$APP/Contents/MacOS/Blurt" | sed 's/^/    /'
for arch in arm64 x86_64; do
  lipo -info "$APP/Contents/MacOS/Blurt" | grep -q "$arch" || {
    echo "release binary is missing the $arch slice" >&2; exit 1; }
done

RELEASE="$ROOT/build/release"
rm -rf "$RELEASE"
mkdir -p "$RELEASE"
ZIP="$RELEASE/Blurt-$VERSION.zip"
DMG="$RELEASE/Blurt-$VERSION.dmg"

# ---------------------------------------------------------------------------
# Notarize the app, then staple it.
#
# The app is notarized inside a zip because the notary service does not accept a
# bare .app, but the ticket is stapled to the .app itself. That matters: Sparkle
# updates hand the extracted app to the user directly, and a stapled app
# validates with no network at all. An unstapled one silently depends on the
# user being online at first launch.
# ---------------------------------------------------------------------------
echo
echo "==> Packaging $(basename "$ZIP")"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ "$SKIP_NOTARIZE" == "0" ]]; then
  echo "==> Notarizing the app (this takes a few minutes)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> Stapling"
  xcrun stapler staple "$APP"

  # Re-zip so the distributed archive contains the stapled app rather than the
  # copy that went to the notary service without a ticket.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

# ---------------------------------------------------------------------------
# The DMG. Plain hdiutil rather than create-dmg: no extra dependency, and the
# window layout is not worth a build-time dependency for a menu bar app whose
# entire install story is one drag.
# ---------------------------------------------------------------------------
echo
echo "==> Packaging $(basename "$DMG")"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
# ditto rather than cp -R, for the same reason the zip above uses it: this app
# is signed and carries a stapled notarization ticket, and ditto is the only
# copy that preserves the extended attributes a bundle's signature depends on.
ditto "$APP" "$STAGE/Blurt.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Blurt" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [[ "$SKIP_NOTARIZE" == "0" ]]; then
  # The DMG is notarized separately from the app it carries. Stapling it means a
  # first-time download opens without Gatekeeper phoning home, which is exactly
  # the moment someone decides whether this app is trustworthy.
  echo "==> Notarizing the disk image"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"

  echo
  echo "==> Verifying as Gatekeeper sees it"
  spctl --assess --type execute --verbose=2 "$APP"
  xcrun stapler validate "$DMG"
fi

# ---------------------------------------------------------------------------
# The appcast: what every installed copy polls to learn this version exists.
#
# Generated from the stapled zip, because the EdDSA signature and the length
# in the feed cover exact bytes and the zip was rebuilt after stapling. And
# generated in a scratch directory holding only that zip: generate_appcast
# turns every archive it finds into a feed item, and the DMG beside it is the
# same version twice. So the feed lists exactly one version — the newest —
# which is all Sparkle needs to answer "is there something newer than me?".
#
# SUFeedURL is GitHub's latest/download/appcast.xml, which redirects to this
# release's copy. Uploading the file with the release is the whole act of
# publishing the update.
# ---------------------------------------------------------------------------
echo
echo "==> Generating the appcast"
FEED_STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE" "$FEED_STAGE"' EXIT
cp "$ZIP" "$FEED_STAGE/"
# Shown inside the update dialog. A fragment without <body>, which is what
# makes generate_appcast embed it rather than link to it.
{
  echo "<h2>Blurt $VERSION</h2>"
  echo "<p>Signed with a Developer ID certificate and notarized by Apple."
  echo "<a href=\"https://github.com/$REPO/releases/tag/$TAG\">Release notes on GitHub.</a></p>"
  if [[ -n "$PREV" ]]; then
    echo "<p><a href=\"https://github.com/$REPO/compare/$PREV...$TAG\">Every change since $PREV.</a></p>"
  fi
} > "$FEED_STAGE/Blurt-$VERSION.html"
# Reads the private key from the keychain; macOS may ask once.
"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO/releases/tag/$TAG" \
  -o "$RELEASE/appcast.xml" \
  "$FEED_STAGE"
APPCAST="$RELEASE/appcast.xml"
# The feed must name this exact version, or installed copies will never see it.
grep -q "sparkle:version=\"$BUILD_NUMBER\"" "$APPCAST" \
  || grep -q "<sparkle:version>$BUILD_NUMBER</sparkle:version>" "$APPCAST" \
  || { echo "appcast does not list build $BUILD_NUMBER" >&2; exit 1; }
# generate_appcast infers hardware requirements from the slices in the zip. A
# universal build yields none; an arm64-only one yields a feed that every
# Intel Mac silently ignores, forever, with nothing in the app to say why.
if grep -q "sparkle:hardwareRequirements" "$APPCAST"; then
  echo "appcast restricts hardware — the release binary is not universal:" >&2
  grep "sparkle:hardwareRequirements" "$APPCAST" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Publish. Tag first: if the upload fails the tag is still the record of what
# was built, and `gh release create` can be re-run against it by hand.
# ---------------------------------------------------------------------------
if [[ "$PUBLISH" == "1" ]]; then
  echo
  echo "==> Tagging $TAG"
  git tag -a "$TAG" -m "Blurt $VERSION"
  git push --quiet origin "$TAG"

  echo "==> Creating the GitHub release"
  NOTES=$(mktemp)
  {
    cat <<EOF
Download **$(basename "$DMG")** below, open it, and drag Blurt to Applications.

Signed with a Developer ID certificate and notarized by Apple, so it opens
without a Gatekeeper warning.

First launch walks you through setup: a transcription provider (bring an API key,
or run a model on your Mac), Microphone, and Accessibility. **Accessibility is
not optional** — without it the hotkey installs successfully and then silently
never fires, so setup will not let you past it.

Requires macOS 13 or newer. Installed copies from 0.1.3 on update themselves.
EOF
    if [[ -n "$PREV" ]]; then
      printf '\n**Changes:** https://github.com/%s/compare/%s...%s\n' "$REPO" "$PREV" "$TAG"
    fi
  } > "$NOTES"

  gh release create "$TAG" "$DMG" "$ZIP" "$APPCAST" \
    --title "Blurt $VERSION" \
    --notes-file "$NOTES"
  rm -f "$NOTES"
fi

echo
echo "OK  $DMG"
echo "OK  $ZIP"
echo "OK  $APPCAST"
if [[ "$PUBLISH" == "1" ]]; then
  echo "OK  $(gh release view "$TAG" --json url -q .url)"
fi
if [[ "$SKIP_NOTARIZE" == "1" ]]; then
  echo
  echo "NOTE  Not notarized. This build runs on this Mac only; anywhere else"
  echo "      Gatekeeper will refuse it with a damaged-file error."
fi
