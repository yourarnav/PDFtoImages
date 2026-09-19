#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="PDF to Images"
APP_DIR="${APP_NAME}.app"
IDENTIFIER="com.arnav.pdftoimages"

# Use CommandLineTools SDK for robust, license-prompt-free compilation
export PATH="/Library/Developer/CommandLineTools/usr/bin:$PATH"
SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"

if [ ! -d "$SDK_PATH" ]; then
    SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || echo '')"
fi

echo "→ Compiling universal binary (arm64 + x86_64)..."
mkdir -p build
clang -fobjc-arc -O3 \
  -arch arm64 -arch x86_64 \
  ${SDK_PATH:+-isysroot "$SDK_PATH"} \
  -mmacosx-version-min=12.0 \
  -framework Cocoa -framework UniformTypeIdentifiers \
  Sources/main.m -o "build/${APP_NAME}"

echo "→ Bundling ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "build/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp "Sources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

echo "→ Ad-hoc codesigning..."
codesign --force --deep -s - "${APP_DIR}"

echo "✓ Successfully built ${APP_DIR}"
lipo -info "${APP_DIR}/Contents/MacOS/${APP_NAME}"
