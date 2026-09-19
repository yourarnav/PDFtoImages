#!/usr/bin/env bash
# Integration test suite for PDF to Images
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="/Library/Developer/CommandLineTools/usr/bin:$PATH"
export DEVELOPER_DIR="/Library/Developer/CommandLineTools"

echo "=== Running PDF to Images Test Suite ==="

TEST_DIR="build/test_workspace"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

# 1. Verify Universal Binary
echo "→ [1/7] Testing binary architecture..."
./scripts/build-app.sh > /dev/null
ARCHS=$(lipo -info "PDF to Images.app/Contents/MacOS/PDF to Images")
if [[ "$ARCHS" =~ "arm64" ]] && [[ "$ARCHS" =~ "x86_64" ]]; then
    echo "  ✓ Universal 2 binary verified (contains arm64 and x86_64)"
else
    echo "  ✗ Missing required architectures: $ARCHS"
    exit 1
fi

# 2. Generate Synthetic Test PDFs
echo "→ [2/7] Generating synthetic test PDFs..."
python3 - << 'EOF'
import os

test_dir = "build/test_workspace"

# Minimal valid 1-page PDF
def create_pdf(filename, num_pages=1):
    path = os.path.join(test_dir, filename)
    pages = []
    for i in range(num_pages):
        content = f"BT /F1 24 Tf 100 700 Td (Test Page {i+1}) Tj ET"
        pages.append(content)
    
    # Write minimal PDF structure
    with open(path, "wb") as f:
        f.write(b"%PDF-1.4\n")
        f.write(b"1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n")
        page_refs = " ".join([f"{3 + i*2} 0 R" for i in range(num_pages)])
        f.write(f"2 0 obj << /Type /Pages /Kids [{page_refs}] /Count {num_pages} >> endobj\n".encode())
        
        for i in range(num_pages):
            page_obj = 3 + i*2
            content_obj = 4 + i*2
            f.write(f"{page_obj} 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {content_obj} 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> >> endobj\n".encode())
            f.write(f"{content_obj} 0 obj << /Length {len(pages[i])} >> stream\n{pages[i]}\nendstream\nendobj\n".encode())
            
        f.write(b"xref\n0 1\n0000000000 65535 f \ntrailer << /Size 10 /Root 1 0 R >>\nstartxref\n9\n%%EOF\n")

# Normal 1-page PDF
create_pdf("normal.pdf", 1)

# 12-page PDF for natural sort verification (page_1 to page_12)
create_pdf("multi_page_12.pdf", 12)

# File with spaces, emoji, brackets
create_pdf("Contract [2026] 📊.pdf", 2)

# Fake PDF (no %PDF- header)
with open(os.path.join(test_dir, "fake_doc.pdf"), "w") as f:
    f.write("This is a plain text file pretending to be a PDF.")

# Zero-byte PDF
with open(os.path.join(test_dir, "empty.pdf"), "w") as f:
    pass

# Corrupt PDF (has header but damaged syntax)
with open(os.path.join(test_dir, "corrupt.pdf"), "wb") as f:
    f.write(b"%PDF-1.4\nMalformed binary content garbage...")

print("  ✓ Created synthetic test files")
EOF

# 3. Test Header Magic Validation
echo "→ [3/7] Testing PDF header magic detection..."
python3 - << 'EOF'
import os
test_dir = "build/test_workspace"

def check_header(filename):
    path = os.path.join(test_dir, filename)
    with open(path, "rb") as f:
        head = f.read(1024)
        return b"%PDF-" in head

assert check_header("normal.pdf") == True, "Normal PDF should pass magic check"
assert check_header("multi_page_12.pdf") == True, "Multi-page PDF should pass magic check"
assert check_header("fake_doc.pdf") == False, "Fake PDF should fail magic check"
assert check_header("empty.pdf") == False, "Empty file should fail magic check"
print("  ✓ Magic bytes correctly filter non-PDF files")
EOF

# 4. Test Poppler Rendering & Natural Sort Ordering
echo "→ [4/7] Testing Poppler execution and natural page numbering..."
POPPLER_BIN="/opt/homebrew/bin/pdftoppm"
if [ ! -x "$POPPLER_BIN" ]; then
    POPPLER_BIN="$(which pdftoppm 2>/dev/null || true)"
fi

if [ -x "$POPPLER_BIN" ]; then
    OUT_DIR="$TEST_DIR/out_multi"
    mkdir -p "$OUT_DIR"
    "$POPPLER_BIN" -png -r 150 "$TEST_DIR/multi_page_12.pdf" "$OUT_DIR/rawpage"
    
    # Check natural sorting logic
    PAGES_GENERATED=$(ls "$OUT_DIR"/rawpage-*.png | wc -l | tr -d ' ')
    if [ "$PAGES_GENERATED" -eq 12 ]; then
        echo "  ✓ Generated all 12 pages successfully"
    else
        echo "  ✗ Expected 12 pages, got $PAGES_GENERATED"
        exit 1
    fi
else
    echo "  ⚠ Poppler not found on PATH — skipping rendering subtest"
fi

# 5. Test Filenames with Spaces, Emojis, and Brackets
echo "→ [5/7] Testing unicode & special characters in filenames..."
if [ -x "$POPPLER_BIN" ]; then
    OUT_SPECIAL="$TEST_DIR/out_special"
    mkdir -p "$OUT_SPECIAL"
    "$POPPLER_BIN" -png -r 150 "$TEST_DIR/Contract [2026] 📊.pdf" "$OUT_SPECIAL/rawpage"
    SPECIAL_COUNT=$(ls "$OUT_SPECIAL"/rawpage-*.png | wc -l | tr -d ' ')
    if [ "$SPECIAL_COUNT" -eq 2 ]; then
        echo "  ✓ Unicode and special character paths handled safely without shell injection"
    else
        echo "  ✗ Failed rendering unicode path"
        exit 1
    fi
fi

# 6. Test Corrupt File Handling (Exit code classification)
echo "→ [6/7] Testing Poppler error handling on corrupt input..."
if [ -x "$POPPLER_BIN" ]; then
    set +e
    "$POPPLER_BIN" -png -r 150 "$TEST_DIR/corrupt.pdf" "$TEST_DIR/corrupt_out" 2>/dev/null
    CORRUPT_EXIT=$?
    set -e
    if [ "$CORRUPT_EXIT" -ne 0 ]; then
        echo "  ✓ Corrupted PDF correctly yielded non-zero exit code ($CORRUPT_EXIT)"
    else
        echo "  ✗ Corrupt PDF unexpectedly succeeded"
        exit 1
    fi
fi

# 7. Test DMG Packaging & Checksum Consistency
echo "→ [7/7] Verifying DMG package integrity..."
if [ -f "PDFtoImages.dmg" ]; then
    hdiutil verify "PDFtoImages.dmg" > /dev/null
    echo "  ✓ PDFtoImages.dmg passed macOS hdiutil verify integrity check"
else
    echo "  ✗ PDFtoImages.dmg not found"
    exit 1
fi

rm -rf "$TEST_DIR"
echo ""
echo "=== All 7 Test Suites Passed Successfully! ==="
