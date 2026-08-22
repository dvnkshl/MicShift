#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_PATH="$PROJECT_DIR/build/MicShift.app"
INFO_PLIST="$PROJECT_DIR/Info.plist"
RELEASE_DIR="$PROJECT_DIR/Release"

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  print "Set DEVELOPER_ID_APPLICATION to the exact Developer ID Application identity."
  print "Example: Developer ID Application: Your Name (TEAMID)"
  exit 1
fi

APP_NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$INFO_PLIST")
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
SAFE_NAME=${APP_NAME// /-}
DMG_PATH="$RELEASE_DIR/$SAFE_NAME-$VERSION.dmg"

if [[ -e "$DMG_PATH" ]]; then
  print "Release already exists; refusing to overwrite: $DMG_PATH"
  exit 1
fi

# Rust embeds source paths in panic strings. Remap build-machine paths in any
# binary intended for public distribution.
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}/=/ --remap-path-prefix=$HOME/=/"

"$PROJECT_DIR/Scripts/build-app.sh"

HELPER_PATH="$APP_PATH/Contents/Resources/dji-link-monitor"
codesign --force --options runtime --timestamp \
  --sign "$DEVELOPER_ID_APPLICATION" "$HELPER_PATH"
codesign --force --options runtime --timestamp \
  --sign "$DEVELOPER_ID_APPLICATION" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$RELEASE_DIR"
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/micshift-release.XXXXXX")
cleanup() {
  case "$STAGING_DIR" in
    /private/var/folders/*|/var/folders/*|/tmp/*)
      find "$STAGING_DIR" -depth -delete
      ;;
    *) print "Refusing to remove unexpected staging path: $STAGING_DIR" ;;
  esac
}
trap cleanup EXIT

ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDZO \
  "$DMG_PATH"
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"

if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
  print "Signed, notarized, and stapled: $DMG_PATH"
else
  print "Signed DMG created but not notarized: $DMG_PATH"
  print "Set NOTARYTOOL_PROFILE to submit and staple it automatically."
fi
