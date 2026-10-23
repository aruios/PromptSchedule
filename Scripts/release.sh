#!/bin/zsh
# Builds PromptSchedule for direct download (outside the Mac App Store):
#   archive → export → .dmg → notarize → staple
#
# Usage:  Scripts/release.sh
#
# For a sellable build you need a "Developer ID Application" certificate in your
# keychain, plus notarization credentials saved once with:
#   xcrun notarytool store-credentials PromptSchedule-notary \
#       --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
# Without the certificate, the script still produces a .dmg signed with your
# development certificate, which runs on this Mac but not on other people's.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PromptSchedule"
NOTARY_PROFILE="${NOTARY_PROFILE:-PromptSchedule-notary}"
OUT="build/release"
ARCHIVE="$OUT/$APP_NAME.xcarchive"
EXPORT="$OUT/export"

VERSION=$(xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -showBuildSettings 2>/dev/null | awk '/ MARKETING_VERSION = / { print $3; exit }')
DMG="$OUT/$APP_NAME-$VERSION.dmg"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "▸ Archiving $APP_NAME $VERSION"
xcodebuild archive -quiet \
    -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -destination "generic/platform=macOS" -archivePath "$ARCHIVE"

if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    SIGNED_FOR_DISTRIBUTION=1
    echo "▸ Exporting with Developer ID"
    cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
EOF
    xcodebuild -exportArchive -quiet \
        -archivePath "$ARCHIVE" -exportPath "$EXPORT" -exportOptionsPlist "$OUT/ExportOptions.plist"
else
    SIGNED_FOR_DISTRIBUTION=0
    echo "⚠︎ No Developer ID Application certificate found."
    echo "  Building a development-signed .dmg for local testing only."
    mkdir -p "$EXPORT"
    cp -R "$ARCHIVE/Products/Applications/$APP_NAME.app" "$EXPORT/"
fi

echo "▸ Creating $DMG"
STAGING="$OUT/dmg"
mkdir -p "$STAGING"
cp -R "$EXPORT/$APP_NAME.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

if [[ $SIGNED_FOR_DISTRIBUTION == 1 ]]; then
    IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')
    codesign --sign "$IDENTITY" --timestamp "$DMG"

    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "▸ Notarizing (this can take a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        echo "✓ Ready to sell: $DMG"
    else
        echo "⚠︎ No notarization profile '$NOTARY_PROFILE'. The .dmg is signed but not notarized;"
        echo "  run the notarytool store-credentials command at the top of this script, then re-run."
    fi
else
    echo "✓ Local test build: $DMG"
fi
