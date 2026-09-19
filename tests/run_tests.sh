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
echo "→ [2/5] Running true AppKit JobManager conversion tests..."
clang -fobjc-arc -O3 \
  -isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  -framework Cocoa -framework UniformTypeIdentifiers \
  tests/test_converter_core.m -o build/test_core
./build/test_core
echo "  ✓ App-level conversion logic, sequential page renaming, and validation verified"

# 3. Poppler Subprocess Smoke Tests (Direct CLI)
echo "→ [3/5] Running Poppler subprocess smoke tests..."
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

# 4. Verify DMG Package Integrity
echo "→ [4/5] Verifying DMG package integrity..."
if [ ! -f "PDFtoImages.dmg" ]; then
    echo "  → Packaging release DMG first..."
    ./scripts/package-dmg.sh > /dev/null
fi
hdiutil verify "PDFtoImages.dmg" > /dev/null
echo "  ✓ PDFtoImages.dmg passed macOS hdiutil verify integrity check"

# 5. Verify DMG Checksum Matches Homebrew Cask Exactly
echo "→ [5/5] Verifying DMG SHA-256 against Homebrew cask..."
ACTUAL_SHA=$(shasum -a 256 "PDFtoImages.dmg" | awk '{print $1}')
CASK_SHA=$(sed -n 's/.*sha256 "\([^"]*\)".*/\1/p' Casks/pdftoimages.rb)

if [ "$ACTUAL_SHA" != "$CASK_SHA" ]; then
    echo "  ✗ Checksum mismatch! DMG is $ACTUAL_SHA, but Cask specifies $CASK_SHA"
    echo "    Update Casks/pdftoimages.rb with the new sha256 or rebuild cleanly."
    exit 1
fi
echo "  ✓ Checksum match verified ($ACTUAL_SHA)"

rm -rf "$TEST_DIR" build/test_core
echo ""
echo "=== All 5 Test Suites Passed Successfully! ==="
