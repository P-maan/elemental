#!/bin/bash
#  install-pre.sh — put the pre-release beside the stable app, and run it.
#
#  The pre-release is a SEPARATELY IDENTIFIED build
#  (com.prakritmaan.elemental.pre) so both can be installed at once. Nothing
#  here touches the stable app or its saver: different bundle id, different
#  name, different ByHost domain.
#
#  What it DOES share is ~/Library/Application Support/Elemental — the same
#  config.json the stable app reads and writes. That is deliberate, because a
#  test build that cannot reproduce your real settings is not testing
#  anything; the price is that the pre-release can write your real config.
#
#  On launch the pre-release quits the stable app, because two of them cannot
#  share a desk — both own the desktop picture and both publish to a saver.
#
#  Usage:   ./install-pre.sh            build, install, launch
#           ./install-pre.sh --no-build
#           ./install-pre.sh --uninstall

set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/Elemental Pre.app"
SAV="$HOME/Library/Screen Savers/Elemental Pre.saver"

if [[ "${1:-}" == "--uninstall" ]]; then
  echo "==> removing the pre-release"
  rm -rf "$APP" "$SAV"
  # Its settings feed, which nothing else reads.
  defaults -currentHost delete com.prakritmaan.elemental.pre.saver 2>/dev/null || true
  pkill -f "Elemental Pre.app" 2>/dev/null || true
  echo "    gone. The stable app and saver were never touched."
  echo "    Reopen it with:  open -g /Applications/Elemental.app"
  exit 0
fi

[[ "${1:-}" == "--no-build" ]] || ./build.sh pre

[[ -d "build/Elemental Pre.app" ]] || { echo "error: build/Elemental Pre.app missing"; exit 1; }

echo "==> installing"
# Quit any previous pre-release first: copying over a running bundle is how you
# get a half-replaced app that launches into the old binary.
pkill -f "Elemental Pre.app" 2>/dev/null || true
sleep 1

rm -rf "$APP"; cp -R "build/Elemental Pre.app" "$APP"
mkdir -p "$HOME/Library/Screen Savers"
rm -rf "$SAV"; cp -R "build/Elemental Pre.saver" "$SAV"

# Per file, not just the bundle root, or the executable inside stays quarantined.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
xattr -dr com.apple.quarantine "$SAV" 2>/dev/null || true

echo "    app   $APP"
echo "    saver $SAV"
echo
echo "==> launching (this quits the stable Elemental)"
open -g "$APP"
echo
echo "    The menu bar item says 'pre-release' so you can tell them apart."
echo "    To test the saver: pick 'Elemental Pre' in System Settings >"
echo "    Screen Saver, let it run once, then:"
echo
echo "      ELEMENTAL_DOMAIN=com.prakritmaan.elemental.pre.saver \\"
echo "        ./build/elemental-render --saverhealth"
echo
echo "    To go back:  ./install-pre.sh --uninstall"
