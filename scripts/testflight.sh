#!/bin/bash
# Archives an app target and uploads it to TestFlight.
#
#   scripts/testflight.sh ios
#   scripts/testflight.sh mac
#
# Needs, in the environment or in .env:
#   DEVELOPMENT_TEAM   ten-character team id from developer.apple.com
#   ASC_KEY_ID         App Store Connect API key id (~/.appstoreconnect/private_keys/AuthKey_<id>.p8)
#   ASC_ISSUER_ID      issuer id from App Store Connect → Users and Access → Integrations
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/.env" ] && { set -a; source "$ROOT/.env"; set +a; }

PLATFORM="${1:-ios}"
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"

case "$PLATFORM" in
  ios) SCHEME=MuonPlayer;    DEST='generic/platform=iOS';   ALTOOL_TYPE=ios;   ARTIFACT='*.ipa' ;;
  mac) SCHEME=MuonPlayerMac; DEST='generic/platform=macOS'; ALTOOL_TYPE=macos; ARTIFACT='*.pkg' ;;
  *) echo "usage: $0 ios|mac" >&2; exit 2 ;;
esac

# Commit count is monotonic and needs no bookkeeping; App Store Connect only
# requires that each upload's build number be higher than the last.
BUILD="${CURRENT_PROJECT_VERSION:-$(git -C "$ROOT" rev-list --count HEAD)}"
OUT="$ROOT/.build/testflight/$PLATFORM"
rm -rf "$OUT" && mkdir -p "$OUT"

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>teamID</key><string>$DEVELOPMENT_TEAM</string>
	<key>uploadSymbols</key><true/>
	<key>destination</key><string>export</string>
</dict>
</plist>
EOF

KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
[ -f "$KEY_PATH" ] || { echo "no API key at $KEY_PATH" >&2; exit 1; }

# No Apple ID is signed into Xcode, so automatic signing has to authenticate
# with the same API key the upload uses, or it cannot mint the certificate.
AUTH=(-authenticationKeyPath "$KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "==> archiving $SCHEME, build $BUILD"
xcodebuild -project "$ROOT/MuonPlayer.xcodeproj" -scheme "$SCHEME" \
  -configuration Release -destination "$DEST" \
  -archivePath "$OUT/$SCHEME.xcarchive" \
  -allowProvisioningUpdates "${AUTH[@]}" \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CURRENT_PROJECT_VERSION="$BUILD" \
  archive

echo "==> exporting"
xcodebuild -exportArchive -archivePath "$OUT/$SCHEME.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" \
  -allowProvisioningUpdates "${AUTH[@]}"

FILE=$(find "$OUT/export" -maxdepth 1 -name "$ARTIFACT" | head -1)
[ -n "$FILE" ] || { echo "no $ARTIFACT in $OUT/export" >&2; exit 1; }

echo "==> validating $(basename "$FILE")"
xcrun altool --validate-app -f "$FILE" -t "$ALTOOL_TYPE" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> uploading"
xcrun altool --upload-app -f "$FILE" -t "$ALTOOL_TYPE" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> done: build $BUILD is processing in App Store Connect"
