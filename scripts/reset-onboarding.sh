#!/usr/bin/env bash
# Put this Mac back to a first-run state, so the setup flow can be tested.
#
#   ./scripts/reset-onboarding.sh [--keys] [--yes]
#
# Setup skips any step whose requirement is already met, which is right for
# users and unhelpful when you are trying to look at the flow: with a key saved
# and both permissions granted, four of the six screens never appear.
#
# The state lives in three places, none of them inside the app bundle, so
# deleting or rebuilding Blurt resets none of it:
#
#   1. The completion marker, in this app's preferences.
#   2. The API key, in the login keychain.
#   3. Microphone and Accessibility, in the TCC databases.
#
# Only the first is cleared by default. --keys adds the second, because getting
# it back means pasting a key you have to still have.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.nerflabs.blurt"
CLEAR_KEYS=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --keys) CLEAR_KEYS=1 ;;
    --yes) ASSUME_YES=1 ;;
    *) echo "unknown flag: $arg" >&2; exit 1 ;;
  esac
done

echo "This will:"
echo "  * forget that setup was ever completed"
echo "  * revoke Blurt's Microphone and Accessibility permissions"
if [[ "$CLEAR_KEYS" == "1" ]]; then
  echo "  * DELETE your saved API keys from the keychain — you will need to"
  echo "    paste them again, so make sure you still have them"
else
  echo
  echo "  Your API keys are left alone, which means the transcription step will"
  echo "  still be skipped. Pass --keys to clear those too."
fi
echo

if [[ "$ASSUME_YES" != "1" ]]; then
  read -r -p "Continue? [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || { echo "Nothing changed."; exit 0; }
fi

# Quit first, and wait for it. A running app holds its preferences in memory and
# writes them back as it exits, which silently undoes the delete below — the
# reset appears to work and then the flow does not appear.
if pgrep -x Blurt >/dev/null 2>&1; then
  echo "==> Quitting Blurt"
  pkill -x Blurt || true
  for _ in $(seq 1 25); do
    pgrep -x Blurt >/dev/null 2>&1 || break
    sleep 0.2
  done
fi

# Just the one key, not the whole domain: wiping every preference would also
# take the hotkey, the modes, the vocabulary and the history settings, none of
# which have anything to do with the flow being tested.
echo "==> Forgetting the completion marker"
defaults delete "$BUNDLE_ID" onboardingCompletedVersion 2>/dev/null \
  || echo "    (was not set)"

if [[ "$CLEAR_KEYS" == "1" ]]; then
  echo "==> Deleting saved API keys"
  for provider in groq openai deepgram; do
    if security delete-generic-password -s "$BUNDLE_ID" -a "$provider" >/dev/null 2>&1; then
      echo "    removed $provider"
    fi
  done
fi

# TCC. Microphone lives in the user database and resets without privileges;
# Accessibility lives in the system one and does not, so it is attempted plainly
# first rather than asking for a password nobody needed.
echo "==> Revoking Microphone"
tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 \
  && echo "    done" || echo "    could not reset (may already be clear)"

echo "==> Revoking Accessibility"
if tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1; then
  echo "    done"
else
  echo "    needs privileges; run:"
  echo "      sudo tccutil reset Accessibility $BUNDLE_ID"
fi

echo
echo "OK  Relaunch with ./scripts/build-macos-app.sh --run"
