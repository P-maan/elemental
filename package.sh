#!/bin/bash
#  package.sh — build a distributable Elemental.pkg.
#
#  WHY A .pkg AND NOT A ZIPPED .app
#
#  Both get quarantined when downloaded from a browser or from a GitHub release.
#  The difference is what happens next, and it is not small:
#
#    zipped .app   Ad-hoc signed plus quarantine gives "Elemental is damaged and
#                  can't be opened." There is no Open Anyway button on that
#                  dialog — the user is told to move it to the Trash, and the
#                  only way forward is a Terminal command they will not find.
#
#    .pkg          Gives "can't be opened because it is from an unidentified
#                  developer", which IS recoverable through the normal route:
#                  right-click > Open, or System Settings > Privacy & Security >
#                  Open Anyway. One click, in a place people have seen before.
#
#  And then the part that actually matters: FILES LAID DOWN BY AN INSTALLER DO
#  NOT INHERIT QUARANTINE. The user clears it once, for the installer, and the
#  app that lands in /Applications is clean — it launches by double-click from
#  then on, forever, with no ceremony. A zipped app is quarantined every single
#  time it is downloaded.
#
#  So without an Apple Developer account this is the best distribution there is.
#  WITH one, set ELEMENTAL_INSTALLER_ID and the dialog disappears entirely.
#
#  Note the certificate for signing an installer is a DIFFERENT one from the
#  certificate for signing an app:
#      app        "Developer ID Application: Name (TEAM)"   -> build.sh
#      installer  "Developer ID Installer: Name (TEAM)"     -> here
#  Being issued one does not give you the other, and mixing them up produces an
#  unhelpful error.
#
#  Usage:
#      ./package.sh                    # builds first, then packages
#      ./package.sh --no-build

set -euo pipefail
cd "$(dirname "$0")"

IDENTIFIER="com.prakritmaan.elemental"
VERSION="$(defaults read "$PWD/App/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0")"
INSTALLER_ID="${ELEMENTAL_INSTALLER_ID:-}"
OUT="build/Elemental-${VERSION}.pkg"

if [[ "${1:-}" != "--no-build" ]]; then
  ./build.sh
fi

[[ -d build/Elemental.app ]] || { echo "error: build/Elemental.app missing"; exit 1; }

# ---- Refuse to ship a build that only runs on the machine that made it.
#
# Two releases went out narrowed to their build host without anything saying so.
# 0.2 was stamped minos 27.0 while its Info.plist advertised 14.0, so it
# installed on macOS 26 and then would not open; it was also arm64-only, so no
# Intel Mac could launch it at all. Both came from build.sh inheriting a
# property of this machine, and both were invisible from this machine, because
# it is the one machine the result was guaranteed to work on.
#
# So the installer checks rather than trusts. ELEMENTAL_ARCHS=arm64 stays
# available for fast local iteration; it just cannot reach a .pkg.
BIN="build/Elemental.app/Contents/MacOS/Elemental"
ARCHS_BUILT="$(lipo -archs "$BIN" 2>/dev/null || echo "")"
MINOS_BUILT="$(vtool -show-build "$BIN" 2>/dev/null | awk '/minos/{print $2; exit}')"
PLIST_MIN="$(defaults read "$PWD/App/Info.plist" LSMinimumSystemVersion 2>/dev/null || echo "?")"

if [[ "${ELEMENTAL_ALLOW_THIN:-}" != "1" ]]; then
  for want in arm64 x86_64; do
    case " $ARCHS_BUILT " in
      *" $want "*) ;;
      *) echo "error: $BIN is missing the $want slice (has: ${ARCHS_BUILT:-none})."
         echo "       An installer must run on every Mac, not just this one."
         echo "       Rebuild with ./build.sh, or set ELEMENTAL_ALLOW_THIN=1 to override."
         exit 1 ;;
    esac
  done
fi
# The binary's real floor must match what Info.plist promises. A package that
# advertises 14.0 and refuses to launch below 27 is worse than one that says so.
if [[ "$MINOS_BUILT" != "$PLIST_MIN" ]]; then
  echo "error: binary minos is $MINOS_BUILT but Info.plist says $PLIST_MIN."
  echo "       Fix DEPLOY_MIN in build.sh or LSMinimumSystemVersion in App/Info.plist."
  exit 1
fi
echo "==> verified: $ARCHS_BUILT, minos $MINOS_BUILT"

STAGE="$(mktemp -d)"
SCRIPTS="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$SCRIPTS"' EXIT

# ---- payload: the app goes to /Applications.
mkdir -p "$STAGE/Applications"
cp -R build/Elemental.app "$STAGE/Applications/"

# The screen saver CANNOT be in the payload. It belongs in ~/Library/Screen
# Savers, which is per-user, and a package payload is installed as root into
# absolute paths — writing to one user's home from a payload is wrong on a
# multi-user Mac and impossible to get right when the installer runs before you
# know who will use it. So it is carried as a resource and copied by the
# postinstall script, which can ask who is actually logged in.
mkdir -p "$SCRIPTS"
cp -R build/Elemental.saver "$SCRIPTS/Elemental.saver"

cat > "$SCRIPTS/postinstall" <<'POST'
#!/bin/bash
# Runs as root after the payload lands.
set -e

# WHO is installing. $USER is root here and $HOME is /var/root, so both are
# useless; this is the supported way to find the console user.
CONSOLE_USER=$(stat -f%Su /dev/console)
[[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" ]] || exit 0
USER_HOME=$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory | awk '{print $2}')
[[ -d "$USER_HOME" ]] || exit 0

SAVERS="$USER_HOME/Library/Screen Savers"
mkdir -p "$SAVERS"
rm -rf "$SAVERS/Elemental.saver"
cp -R "$(dirname "$0")/Elemental.saver" "$SAVERS/Elemental.saver"
# Laid down by root, so hand it back or the user cannot replace it on upgrade.
chown -R "$CONSOLE_USER" "$SAVERS/Elemental.saver"

# Belt and braces. Installer payloads are not quarantined, so this should be a
# no-op — but it costs nothing and turns a silent Gatekeeper refusal into a
# non-event if that ever changes.
xattr -dr com.apple.quarantine /Applications/Elemental.app 2>/dev/null || true
xattr -dr com.apple.quarantine "$SAVERS/Elemental.saver" 2>/dev/null || true

exit 0
POST
chmod +x "$SCRIPTS/postinstall"

echo "==> building $OUT (version $VERSION)"
COMPONENT="$(mktemp -d)/component.pkg"
pkgbuild --root "$STAGE" \
         --scripts "$SCRIPTS" \
         --identifier "$IDENTIFIER" \
         --version "$VERSION" \
         --install-location / \
         "$COMPONENT"

if [[ -n "$INSTALLER_ID" ]]; then
  productbuild --package "$COMPONENT" --sign "$INSTALLER_ID" "$OUT"
  echo "  signed with: $INSTALLER_ID"
  if [[ -n "${ELEMENTAL_NOTARY_PROFILE:-}" ]]; then
    echo "  notarizing"
    xcrun notarytool submit "$OUT" --keychain-profile "$ELEMENTAL_NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
  fi
else
  productbuild --package "$COMPONENT" "$OUT"
  echo
  echo "  UNSIGNED. This installs correctly, but on a Mac that downloaded it the"
  echo "  first open needs: right-click > Open, or System Settings > Privacy &"
  echo "  Security > Open Anyway. The app it installs is NOT quarantined and"
  echo "  opens normally from then on."
fi

echo "==> $OUT"
ls -lh "$OUT" | awk '{print "   ", $5, $NF}'
