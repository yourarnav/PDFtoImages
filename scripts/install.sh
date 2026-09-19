#!/usr/bin/env bash
# Install PDF to Images to /Applications for Spotlight & Launchpad
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PDF to Images"
TARGET_DIR="/Applications/${APP_NAME}.app"

echo "→ Building latest release..."
./scripts/build-app.sh

echo "→ Installing to /Applications..."
pkill -x "${APP_NAME}" 2>/dev/null || true
sleep 0.5
rm -rf "$TARGET_DIR"
cp -R "${APP_NAME}.app" "$TARGET_DIR"
touch "$TARGET_DIR"

# Strip quarantine flag so first launch opens seamlessly
xattr -dr com.apple.quarantine "$TARGET_DIR" 2>/dev/null || true

echo "✓ Installed to $TARGET_DIR"
echo "  Launch it via Spotlight, Launchpad, or 'open \"$TARGET_DIR\"'"
