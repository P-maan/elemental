#!/bin/bash
#  install.sh — put Elemental on a Mac that did not build it.
#
#  WHY THIS EXISTS
#
#  Elemental is signed ad hoc unless a Developer ID is configured (see build.sh).
#  An ad-hoc bundle runs perfectly on any Mac — what it cannot survive is the
#  QUARANTINE attribute, which macOS attaches to anything that arrives through a
#  browser download or AirDrop. Ad hoc plus quarantine is what produces:
#
#      "Elemental is damaged and can't be opened. You should move it to the Trash."
#
#  which is a lie. Nothing is damaged. Gatekeeper cannot find a Developer ID or a
#  notarization ticket for a quarantined bundle and reports it in the least
#  helpful way available.
#
#  So there are two honest ways to install without an Apple Developer account:
#
#    1. COPY IT WITHOUT QUARANTINE. A USB stick, scp, rsync or `cp` over a
#       network share does not set the attribute at all, and the app simply
#       works. This is the best route for a machine you can touch — a parent's
#       laptop, your own second Mac.
#
#    2. STRIP THE QUARANTINE AFTER DOWNLOADING. One command, which is what this
#       script does. Needed when the app arrived from a website.
#
#  Neither is a security bypass in any meaningful sense: you are telling your own
#  Mac that you trust software you deliberately fetched. It is the same judgement
#  Gatekeeper asks you to make in System Settings, made at the command line.
#
#  The permanent fix is a Developer ID certificate and notarization — then none
#  of this is needed and the app opens by double-click like anything else. See
#  the signing section of build.sh.
#
#  Usage:
#      ./install.sh                    # install from ./build
#      ./install.sh /path/to/Elemental.app

set -euo pipefail

SRC="${1:-}"
if [[ -z "$SRC" ]]; then
  cd "$(dirname "$0")"
  SRC="build/Elemental.app"
  SAVER="build/Elemental.saver"
else
  SAVER="$(dirname "$SRC")/Elemental.saver"
fi

if [[ ! -d "$SRC" ]]; then
  echo "error: no app at $SRC"
  echo "Run ./build.sh first, or pass the path to Elemental.app."
  exit 1
fi

echo "==> Installing Elemental"

# ---- the app
APPS="/Applications"
echo "  app    -> $APPS/Elemental.app"
# Quit a running copy first: replacing a bundle underneath a live process leaves
# it running the old code with the new resources, which fails in confusing ways.
pkill -f "Elemental.app/Contents/MacOS" 2>/dev/null || true
sleep 1

# An existing install may be ROOT-OWNED, because package.sh's installer put it
# there. A plain `rm -rf` then fails on every file inside it, prints a wall of
# "Permission denied", and — the part that actually bites — CARRIES ON, so the
# old app is still in place, still gets launched, and the user is told the
# install succeeded while running the previous version. Refuse instead, and say
# exactly what to do.
if [[ -e "$APPS/Elemental.app" && ! -w "$APPS/Elemental.app" ]]; then
  if [[ $EUID -ne 0 ]]; then
    echo
    echo "  The copy in /Applications was installed by the .pkg and is owned by root,"
    echo "  so it cannot be replaced without elevated rights. Either:"
    echo
    echo "      sudo ./install.sh          # replace it in place"
    echo "      open build/Elemental-*.pkg  # or reinstall through the installer"
    echo
    exit 1
  fi
fi
rm -rf "$APPS/Elemental.app"
cp -R "$SRC" "$APPS/Elemental.app"
# Installed under sudo, the bundle would be left owned by root and the next
# plain run would hit exactly the problem above. Hand it back.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
  chown -R "$SUDO_USER" "$APPS/Elemental.app"
fi

# ---- the screen saver, if it was built
#
# The same root-ownership trap as the app, in the user's own Library this
# time: one earlier `sudo ./install.sh` left the saver owned by root, every
# later plain run failed to replace it, and the saver quietly kept running a
# build weeks old while the app moved on. So: under sudo, install into the
# INVOKING user's Library (not root's) and hand the bundle back to them; and
# without sudo, refuse loudly rather than leave a stale saver in place.
USER_HOME="$HOME"
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
  USER_HOME="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')"
fi
if [[ -d "$SAVER" ]]; then
  SAVERS="$USER_HOME/Library/Screen Savers"
  echo "  saver  -> $SAVERS/Elemental.saver"
  mkdir -p "$SAVERS"
  if [[ -e "$SAVERS/Elemental.saver" && ! -w "$SAVERS/Elemental.saver" && $EUID -ne 0 ]]; then
    echo
    echo "  The installed screen saver is owned by root (left by an earlier sudo run),"
    echo "  so it cannot be replaced. Fix it once with:"
    echo
    echo "      sudo chown -R \$USER ~/Library/Screen\\ Savers/Elemental.saver"
    echo
    echo "  then run ./install.sh again. The app above was installed."
  else
    rm -rf "$SAVERS/Elemental.saver"
    cp -R "$SAVER" "$SAVERS/Elemental.saver"
    if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
      chown -R "$SUDO_USER" "$SAVERS/Elemental.saver"
    fi
  fi
fi

# ---- the quarantine
#
# Recursive: the attribute is set per file, so clearing only the bundle root
# leaves the executable inside it still quarantined and the app still refused.
echo "  clearing quarantine"
xattr -dr com.apple.quarantine "$APPS/Elemental.app" 2>/dev/null || true
[[ -d "$USER_HOME/Library/Screen Savers/Elemental.saver" ]] && \
  xattr -dr com.apple.quarantine "$USER_HOME/Library/Screen Savers/Elemental.saver" 2>/dev/null || true

# ---- verify rather than assume
if xattr -l "$APPS/Elemental.app" 2>/dev/null | grep -q "com.apple.quarantine"; then
  echo "  WARNING: quarantine is still set. Gatekeeper will refuse to open this."
  echo "  Try:  sudo xattr -dr com.apple.quarantine $APPS/Elemental.app"
  exit 1
fi

echo "==> Done."
echo
echo "Open it with:  open -g $APPS/Elemental.app"
echo "Elemental has no Dock icon — it lives in the menu bar."
echo "To use the screen saver: System Settings > Screen Saver > Elemental."
