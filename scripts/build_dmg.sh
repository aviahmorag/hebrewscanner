#!/bin/bash
#
# build_dmg.sh - Create a distributable DMG for HebrewScanner
#
# Prerequisites:
#   brew install create-dmg fileicon
#
# Usage:
#   ./scripts/build_dmg.sh /path/to/HebrewScanner.app
#

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 /path/to/HebrewScanner.app"
    exit 1
fi

APP_PATH="$1"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH not found"
    exit 1
fi

# Check dependencies
command -v fileicon >/dev/null 2>&1 || { echo "Install fileicon: brew install fileicon"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DMG_PATH="${PROJECT_DIR}/HebrewScanner.dmg"
TEMP_DMG="/tmp/HebrewScanner_rw.dmg"
VOLUME_NAME="HebrewScanner"
ICON_FILE="${APP_PATH}/Contents/Resources/AppIcon.icns"
APPS_ICON="/tmp/hebrewscanner_apps_icon.png"
BG_IMG="/tmp/hebrewscanner_dmg_bg.png"

echo "Building DMG for: $APP_PATH"

# Extract Applications folder icon
swift - <<'SWIFT'
import AppKit
let ws = NSWorkspace.shared
let icon = ws.icon(forFile: "/Applications")
icon.size = NSSize(width: 512, height: 512)
let tiffData = icon.tiffRepresentation!
let bitmap = NSBitmapImageRep(data: tiffData)!
let pngData = bitmap.representation(using: .png, properties: [:])!
try! pngData.write(to: URL(fileURLWithPath: "/tmp/hebrewscanner_apps_icon.png"))
SWIFT

# Generate background image with arrow
python3 - <<'PYTHON'
from PIL import Image, ImageDraw, ImageFont

W, H = 600, 400
img = Image.new("RGBA", (W, H), (255, 255, 255, 255))
draw = ImageDraw.Draw(img)

for y in range(H):
    r = int(245 - (y / H) * 15)
    g = int(247 - (y / H) * 15)
    b = int(250 - (y / H) * 10)
    draw.line([(0, y), (W, y)], fill=(r, g, b, 255))

arrow_y = 185
draw.line([(220, arrow_y), (365, arrow_y)], fill=(120, 120, 120, 255), width=3)
draw.polygon([(380, arrow_y), (362, arrow_y - 9), (362, arrow_y + 9)], fill=(120, 120, 120, 255))

try:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 13)
except:
    font = ImageFont.load_default()

text = "Drag to Applications"
bbox = draw.textbbox((0, 0), text, font=font)
draw.text(((W - (bbox[2] - bbox[0])) // 2, arrow_y + 25), text, fill=(140, 140, 140, 255), font=font)

img.save("/tmp/hebrewscanner_dmg_bg.png")
PYTHON

# Clean up
rm -f "$TEMP_DMG" "$DMG_PATH"
hdiutil detach "/Volumes/${VOLUME_NAME}" 2>/dev/null || true

# Create writable DMG
APP_SIZE=$(du -sm "$APP_PATH" | cut -f1)
DMG_SIZE=$((APP_SIZE + 20))
hdiutil create -size ${DMG_SIZE}m -fs HFS+ -volname "$VOLUME_NAME" "$TEMP_DMG"

# Mount
DEVICE=$(hdiutil attach "$TEMP_DMG" -readwrite -noverify | tail -1 | awk '{print $1}')
MOUNT_DIR="/Volumes/${VOLUME_NAME}"
echo "Mounted at: $MOUNT_DIR"

# Copy app
cp -R "$APP_PATH" "$MOUNT_DIR/"

# Create Finder alias to Applications
osascript -e "tell application \"Finder\" to make new alias file at POSIX file \"$MOUNT_DIR\" to POSIX file \"/Applications\" with properties {name:\"Applications\"}"

# Set Applications folder icon
fileicon set "$MOUNT_DIR/Applications" "$APPS_ICON"

# Background
mkdir "$MOUNT_DIR/.background"
cp "$BG_IMG" "$MOUNT_DIR/.background/bg.png"

# Volume icon
cp "$ICON_FILE" "$MOUNT_DIR/.VolumeIcon.icns"
SetFile -a C "$MOUNT_DIR"

# Configure Finder window
osascript <<'APPLESCRIPT'
tell application "Finder"
    tell disk "HebrewScanner"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 800, 520}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set background picture of theViewOptions to file ".background:bg.png"
        set position of item "HebrewScanner.app" of container window to {150, 185}
        set position of item "Applications" of container window to {450, 185}
        close
        open
        update without registering applications
        delay 3
        close
    end tell
end tell
APPLESCRIPT

sync
sleep 2

# Unmount and compress
hdiutil detach "$DEVICE"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$TEMP_DMG"

echo ""
echo "DMG created: $DMG_PATH"
