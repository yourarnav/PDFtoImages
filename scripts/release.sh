#!/usr/bin/env bash
# End-to-end release pipeline for PDF to Images
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="/Library/Developer/CommandLineTools/usr/bin:$PATH"
export DEVELOPER_DIR="/Library/Developer/CommandLineTools"

echo "=================================================="
echo "      PDF to Images — Official Release Pipeline   "
echo "=================================================="
echo ""

# 1. Run full test suite first
echo "→ [1/5] Running test suite before release build..."
./tests/run_tests.sh

# 2. Build pristine fresh application
echo "→ [2/5] Building pristine Universal 2 application..."
./scripts/build-app.sh

# 3. Always package fresh DMG (removes old DMG)
echo "→ [3/5] Packaging fresh release DMG..."
./scripts/package-dmg.sh

# 4. Extract new SHA-256 and synchronize Cask formula
echo "→ [4/5] Synchronizing Casks/pdftoimages.rb with fresh DMG SHA-256..."
DMG_FILE="PDFtoImages.dmg"
NEW_SHA=$(shasum -a 256 "$DMG_FILE" | awk '{print $1}')
sed -i '' "s/sha256 \".*\"/sha256 \"$NEW_SHA\"/" Casks/pdftoimages.rb

# 5. Integrity & Consistency Verification
echo "→ [5/5] Verifying DMG integrity and Cask equality..."
hdiutil verify "$DMG_FILE" > /dev/null
VERIFIED_CASK_SHA=$(sed -n 's/.*sha256 "\([^"]*\)".*/\1/p' Casks/pdftoimages.rb)

if [ "$NEW_SHA" != "$VERIFIED_CASK_SHA" ]; then
    echo "  ✗ Verification error: Cask was not updated correctly!"
    exit 1
fi

echo ""
echo "=================================================="
echo "✓ Release Build Ready!"
echo "  Artifact: $DMG_FILE"
echo "  SHA-256:  $NEW_SHA"
echo "  Cask:     Casks/pdftoimages.rb (updated)"
echo "=================================================="
echo ""
echo "Next steps to publish:"
echo "  1. git commit -am \"Release v1.0.0\""
echo "  2. git tag v1.0.0 -f && git push origin main --tags -f"
echo "  3. gh release upload v1.0.0 PDFtoImages.dmg --clobber"
echo "  4. Update yourarnav/homebrew-tap with Casks/pdftoimages.rb"
