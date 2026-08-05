#!/usr/bin/env bash
#
# release.sh — build, Developer ID sign, notarise and staple SidePulse, and
# wrap it in a disk image that opens without any Gatekeeper warning.
#
#   ./release.sh              -> dist/SidePulse-<version>.dmg
#   ./release.sh --skip-tests  skip the test suite (not recommended)
#
# This is the distributable path. `build.sh` ad-hoc signs, which is fine on the
# machine that built it and refused everywhere else.
#
# One-time setup:
#
#   1. A **Developer ID Application** certificate in your login keychain. An
#      "Apple Development" certificate is not the same thing and cannot be
#      notarised — it is for running on your own registered devices. Create one
#      in Xcode (Settings -> Accounts -> Manage Certificates -> + -> Developer
#      ID Application) or on developer.apple.com, then:
#
#        security find-identity -v -p codesigning     # copy the exact name
#        export SIDEPULSE_SIGN_IDENTITY="Developer ID Application: You (TEAMID)"
#
#   2. Notarisation credentials, stored once in the keychain so the
#      app-specific password never appears in a script or an env file again:
#
#        xcrun notarytool store-credentials "SIDEPULSE_NOTARY" \
#          --apple-id "you@example.com" \
#          --team-id "TEAMID" \
#          --password "abcd-efgh-ijkl-mnop"   # app-specific, appleid.apple.com
#
#        export SIDEPULSE_NOTARY_PROFILE="SIDEPULSE_NOTARY"
#
set -euo pipefail

cd "$(dirname "$0")"
REPO="$(cd ../.. && pwd)"

: "${SIDEPULSE_SIGN_IDENTITY:?set SIDEPULSE_SIGN_IDENTITY to your Developer ID Application identity — see the header of this script}"
: "${SIDEPULSE_NOTARY_PROFILE:?set SIDEPULSE_NOTARY_PROFILE to your notarytool keychain profile — see the header of this script}"

SKIP_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --skip-tests) SKIP_TESTS=1 ;;
    -h|--help) sed -n '3,31p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

APP_NAME="SidePulse"
OUT="dist"
BUNDLE="$OUT/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG="$OUT/$APP_NAME-$VERSION.dmg"
STAGING="$OUT/staging"

# ── Preflight ────────────────────────────────────────────────────────────────
# Both of these fail late and confusingly if they are wrong, so check up front.
say "Preflight"
security find-identity -v -p codesigning | grep -qF "$SIDEPULSE_SIGN_IDENTITY" \
  || fail "no codesigning identity matching '$SIDEPULSE_SIGN_IDENTITY'. Run: security find-identity -v -p codesigning"
case "$SIDEPULSE_SIGN_IDENTITY" in
  "Developer ID Application"*) ;;
  *) fail "'$SIDEPULSE_SIGN_IDENTITY' is not a Developer ID Application identity. Apple Development and Apple Distribution certificates cannot be notarised." ;;
esac
xcrun notarytool history --keychain-profile "$SIDEPULSE_NOTARY_PROFILE" >/dev/null 2>&1 \
  || fail "notarytool cannot use profile '$SIDEPULSE_NOTARY_PROFILE'. See the header of this script."
echo "  identity: $SIDEPULSE_SIGN_IDENTITY"
echo "  version:  $VERSION"

# ── Tests ────────────────────────────────────────────────────────────────────
if [ "$SKIP_TESTS" = 0 ]; then
  say "Tests"
  ( cd "$REPO" && python3 tools/validate_fixtures.py >/dev/null && echo "  fixtures ok" )
  ( cd "$REPO" && python3 tools/test_sidepulse_solo.py  | tail -1 | sed 's/^/  /' )
  ( cd "$REPO" && python3 tools/test_sidepulse_event.py | tail -1 | sed 's/^/  /' )
  ( cd "$REPO" && swiftc -O -o /tmp/sp-hookstests \
      macos/SidePulseMac/Sources/SidePulseMac/AgentHooks.swift \
      tools/swift-hooks-tests/main.swift \
    && SIDEPULSE_AGENT_HOME=/tmp/sp-hooks-sandbox /tmp/sp-hookstests /tmp/sp-hooks-sandbox | tail -1 | sed 's/^/  /' )
fi

# ── Build ────────────────────────────────────────────────────────────────────
say "Building $APP_NAME $VERSION"
./build.sh >/dev/null
[ -d "$BUNDLE" ] || fail "build.sh produced no bundle at $BUNDLE"

# ── Sign ─────────────────────────────────────────────────────────────────────
# --options runtime is the hardened runtime, which notarisation requires.
# --timestamp binds a trusted timestamp so the signature stays valid after the
# certificate expires. Neither is optional for distribution.
say "Signing with Developer ID"
codesign --force --options runtime --timestamp \
         --sign "$SIDEPULSE_SIGN_IDENTITY" \
         --identifier com.sidepulse.mac \
         "$BUNDLE"
codesign --verify --strict --verbose=2 "$BUNDLE"

# ── Disk image ───────────────────────────────────────────────────────────────
# A symlink to /Applications next to the app is what makes the window a
# drag-to-install target rather than something to double-click in place.
say "Building $DMG"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" \
               -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"

# The disk image is itself a distributed artefact, so it is signed too.
codesign --force --sign "$SIDEPULSE_SIGN_IDENTITY" --timestamp "$DMG"

# ── Notarise ─────────────────────────────────────────────────────────────────
# Notarising the .dmg covers the app inside it, so one round trip does both.
say "Notarising (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$SIDEPULSE_NOTARY_PROFILE" --wait

# Stapling attaches the ticket to the file, so a first launch works offline.
say "Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ── Verify the way Gatekeeper will ───────────────────────────────────────────
say "Verifying"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo

say "Done: $DMG"
cat <<NEXT

Check it the way a stranger would, on a Mac that never built it:

  xattr -w com.apple.quarantine \\
    "0083;00000000;Safari;|com.apple.Safari" "$DMG"
  open "$DMG"

It should mount and the app should launch with no warning at all — not the
"downloaded from the Internet, are you sure" dialog, and not the "unidentified
developer" refusal.

Attach it to a release with:

  gh release create v$VERSION "$DMG" --title "SidePulse $VERSION"
  # or, for an existing tag:
  gh release upload v$VERSION "$DMG" --clobber
NEXT
