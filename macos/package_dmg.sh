#!/usr/bin/env bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$DIR/NacMac.app"
DMG_NAME="NacMac-v1.0.0.dmg"
OUTPUT_DMG="$DIR/$DMG_NAME"
ROOT_DMG="$DIR/../$DMG_NAME"
STAGING_DIR="/tmp/nacmac_dmg_staging_$$"

# Ensure .app is built first
if [ ! -d "$APP_DIR" ]; then
    echo "[*] NacMac.app not found. Running package_app.sh first..."
    "$DIR/package_app.sh"
fi

echo "[*] Creating DMG staging environment..."
rm -rf "$STAGING_DIR" "$OUTPUT_DMG" "$ROOT_DMG"
mkdir -p "$STAGING_DIR"

echo "[*] Copying NacMac.app to staging..."
cp -R "$APP_DIR" "$STAGING_DIR/NacMac.app"

echo "[*] Adding Applications link for drag-and-drop installation..."
ln -s /Applications "$STAGING_DIR/Applications"

echo "[*] Creating compressed disk image: $DMG_NAME..."
hdiutil create -volname "NacMac" -srcfolder "$STAGING_DIR" -ov -format UDZO "$OUTPUT_DMG"

# Also copy to root for easy user access
cp "$OUTPUT_DMG" "$ROOT_DMG"

rm -rf "$STAGING_DIR"

echo "[✓] NacMac DMG successfully created at:"
echo "    $OUTPUT_DMG"
echo "    $ROOT_DMG"
