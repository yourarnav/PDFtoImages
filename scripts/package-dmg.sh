#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PDF to Images"
DMG_NAME="PDFtoImages.dmg"
VOLUME_NAME="PDF to Images"
STAGING_DIR="build/dmg-staging"

echo "→ Ensuring latest app is built..."
./scripts/build-app.sh

echo "→ Preparing DMG staging directory..."
rm -rf "$STAGING_DIR" "$DMG_NAME"
mkdir -p "$STAGING_DIR"

echo "→ Copying application and creating Applications link..."
cp -R "${APP_NAME}.app" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "→ Generating compressed DMG disk image..."
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_NAME"

rm -rf "$STAGING_DIR"

SHA256=$(shasum -a 256 "$DMG_NAME" | awk '{print $1}')
SIZE=$(ls -lh "$DMG_NAME" | awk '{print $5}')

echo ""
echo "=================================================="
echo "✓ Successfully created $DMG_NAME ($SIZE)"
echo "  SHA256: $SHA256"
echo "=================================================="
echo ""
echo "Formula snippet for yourarnav/homebrew-tap (Casks/pdftoimages.rb):"
echo "--------------------------------------------------"
echo "  version \"1.0.0\""
echo "  sha256 \"$SHA256\""
echo "--------------------------------------------------"
