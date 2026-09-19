#!/usr/bin/env bash
# Integration test suite for PDF to Images
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="/Library/Developer/CommandLineTools/usr/bin:$PATH"
export DEVELOPER_DIR="/Library/Developer/CommandLineTools"

echo "=== Running PDF to Images Comprehensive Test Suite ==="

TEST_DIR="build/test_workspace"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

# 1. Verify Universal Binary
echo "→ [1/5] Testing binary architecture..."
./scripts/build-app.sh > /dev/null
ARCHS=$(lipo -info "PDF to Images.app/Contents/MacOS/PDF to Images")
if [[ "$ARCHS" =~ "arm64" ]] && [[ "$ARCHS" =~ "x86_64" ]]; then
    echo "  ✓ Universal 2 binary verified (contains arm64 and x86_64)"
else
    echo "  ✗ Missing required architectures: $ARCHS"
    exit 1
fi

# 2. Compile & Run True App-Level JobManager Test Harness
echo "→ [2/4] Running true AppKit JobManager conversion tests (with 60s timeout)..."
SDK_PATH=$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
clang -fobjc-arc -O3 \
  -isysroot "$SDK_PATH" \
  -framework Cocoa -framework UniformTypeIdentifiers \
  tests/test_converter_core.m -o build/test_core
./build/test_core
echo "  ✓ App-level conversion logic, sequential page renaming, and validation verified"

# 3. Poppler Subprocess Smoke Tests (Direct CLI)
echo "→ [3/4] Running Poppler subprocess smoke tests..."
POPPLER_BIN="/opt/homebrew/bin/pdftoppm"
if [ ! -x "$POPPLER_BIN" ]; then
    POPPLER_BIN="$(which pdftoppm 2>/dev/null || true)"
fi

if [ -x "$POPPLER_BIN" ]; then
    # Generate minimal test PDF
    python3 -c '
import os
with open("build/test_workspace/smoke.pdf", "wb") as f:
    f.write(b"%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >> endobj\n4 0 obj << /Length 0 >> stream\nendstream\nendobj\nxref\n0 5\n0000000000 65535 f \ntrailer << /Size 5 /Root 1 0 R >>\nstartxref\n9\n%%EOF\n")
'
    "$POPPLER_BIN" -png -r 150 "build/test_workspace/smoke.pdf" "build/test_workspace/smoke_out"
    if [ -f "build/test_workspace/smoke_out-1.png" ]; then
        echo "  ✓ Poppler pdftoppm binary confirmed operational"
    else
        echo "  ✗ Poppler failed to produce output"
        exit 1
    fi
else
    echo "  ⚠ Poppler not found on PATH — skipping CLI smoke test"
fi

# 4. DMG Package & Cask Consistency (If DMG exists)
echo "→ [4/4] Verifying DMG package integrity & Cask alignment..."
if [ -f "PDFtoImages.dmg" ]; then
    hdiutil verify "PDFtoImages.dmg" > /dev/null
    echo "  ✓ Existing PDFtoImages.dmg passed hdiutil verify integrity check"
    ACTUAL_SHA=$(shasum -a 256 "PDFtoImages.dmg" | awk '{print $1}')
    CASK_SHA=$(sed -n 's/.*sha256 "\([^"]*\)".*/\1/p' Casks/pdftoimages.rb)
    if [ "$ACTUAL_SHA" != "$CASK_SHA" ]; then
        echo "  ✗ Stale DMG / Cask mismatch detected!"
        echo "    Existing DMG is $ACTUAL_SHA, but Cask specifies $CASK_SHA"
        echo "    Run ./scripts/release.sh to package a fresh DMG and synchronize the cask."
        exit 1
    fi
    echo "  ✓ Checksum match verified ($ACTUAL_SHA)"
else
    echo "  ℹ No local PDFtoImages.dmg present; run ./scripts/release.sh to build fresh DMG & cask."
fi

rm -rf "$TEST_DIR" build/test_core
echo ""
echo "=== Test Suite Passed Successfully! ==="
