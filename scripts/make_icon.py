#!/usr/bin/env python3
import os
import subprocess
import tempfile
from PIL import Image, ImageDraw, ImageFont

def create_app_icon():
    size = 1024
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Outer squircle / rounded rect with subtle gradient
    rect = [80, 80, 944, 944]
    radius = 200

    # Draw rounded background (Coral / Crimson PDF gradient)
    draw.rounded_rectangle(rect, radius=radius, fill=(235, 65, 55, 255), outline=(200, 45, 35, 255), width=6)

    # Inner document card (white with subtle shadow)
    doc_rect = [260, 220, 764, 800]
    draw.rounded_rectangle(doc_rect, radius=40, fill=(255, 255, 255, 255))

    # Folded corner effect
    corner_poly = [(664, 220), (764, 320), (664, 320)]
    draw.polygon(corner_poly, fill=(210, 215, 225, 255))
    draw.line([(664, 220), (664, 320), (764, 320)], fill=(180, 185, 195, 255), width=4)

    # Red PDF Badge on doc
    badge_rect = [320, 360, 520, 460]
    draw.rounded_rectangle(badge_rect, radius=18, fill=(225, 45, 40, 255))

    # Badge text
    try:
        font_large = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 60)
        font_sub = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 48)
    except Exception:
        font_large = ImageFont.load_default()
        font_sub = ImageFont.load_default()

    draw.text((350, 380), "PDF", font=font_large, fill=(255, 255, 255, 255))

    # Image photo icon lines on bottom
    draw.rounded_rectangle([320, 520, 704, 550], radius=10, fill=(200, 205, 215, 255))
    draw.rounded_rectangle([320, 580, 620, 610], radius=10, fill=(200, 205, 215, 255))
    draw.rounded_rectangle([320, 640, 540, 670], radius=10, fill=(200, 205, 215, 255))

    # Arrow indicator converting to images
    draw.text((370, 710), "→ PNG", font=font_sub, fill=(225, 45, 40, 255))

    # Output paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.abspath(os.path.join(script_dir, ".."))
    resources_dir = os.path.join(project_root, "Resources")
    os.makedirs(resources_dir, exist_ok=True)
    
    # Also save PNG for web
    website_assets = os.path.join(project_root, "Website", "assets")
    os.makedirs(website_assets, exist_ok=True)
    img.save(os.path.join(website_assets, "app-icon.png"), "PNG")
    img.resize((128, 128), Image.Resampling.LANCZOS).save(os.path.join(website_assets, "favicon.png"), "PNG")

    with tempfile.TemporaryDirectory() as tmpdir:
        iconset_dir = os.path.join(tmpdir, "AppIcon.iconset")
        os.makedirs(iconset_dir, exist_ok=True)

        sizes = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png")
        ]

        for s, name in sizes:
            resized = img.resize((s, s), Image.Resampling.LANCZOS)
            resized.save(os.path.join(iconset_dir, name))

        # Convert to .icns using macOS iconutil
        icns_path = os.path.join(resources_dir, "AppIcon.icns")
        env = dict(os.environ)
        env["DEVELOPER_DIR"] = "/Library/Developer/CommandLineTools"
        subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", icns_path], check=True, env=env)
        print(f"✓ Generated AppIcon.icns in {resources_dir}")

if __name__ == "__main__":
    create_app_icon()
