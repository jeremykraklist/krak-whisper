#!/bin/bash
# build-mac-app.sh — Build KrakWhisperMac as a proper .app bundle
#
# Usage: ./build-mac-app.sh [--release]
# Output: build/KrakWhisper.app/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BUILD_CONFIG="debug"
if [[ "${1:-}" == "--release" ]]; then
    BUILD_CONFIG="release"
fi

APP_NAME="KrakWhisper"
BUNDLE_ID="com.krakowskilabs.KrakWhisper"
VERSION="1.0.0"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MIN_MACOS="14.0"

echo "▸ Building KrakWhisperMac ($BUILD_CONFIG)..."
swift build --product KrakWhisperMac -c "$BUILD_CONFIG"

# Find the built executable (SPM puts it in arch-specific dir)
BIN_PATH=$(swift build --product KrakWhisperMac -c "$BUILD_CONFIG" --show-bin-path 2>/dev/null)
EXEC_PATH="$BIN_PATH/KrakWhisperMac"

if [[ ! -f "$EXEC_PATH" ]]; then
    echo "✗ Build failed — executable not found at $EXEC_PATH"
    exit 1
fi

echo "▸ Creating .app bundle..."
APP_DIR="build/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# Copy executable
cp "$EXEC_PATH" "$MACOS/$APP_NAME"

# Create Info.plist
cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>KrakWhisper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>KrakWhisper needs microphone access to record speech for on-device transcription.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Generate app icon from SF Symbol (mic.circle.fill) if iconutil is available
# For now, create a simple icns from the system
if command -v sips &>/dev/null && command -v iconutil &>/dev/null; then
    ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$ICONSET_DIR"

    # Create a simple blue mic icon using Python
    python3 -c "
import subprocess, os, tempfile

# Use sips to create solid color images at each size
sizes = [16, 32, 64, 128, 256, 512, 1024]
iconset = '$ICONSET_DIR'

for size in sizes:
    # Create a blue square PNG
    path = os.path.join(iconset, f'icon_{size}x{size}.png')
    path2x = os.path.join(iconset, f'icon_{size//2}x{size//2}@2x.png') if size > 16 else None

    # Use tiffutil + sips to create colored square
    subprocess.run([
        'sips', '-z', str(size), str(size),
        '-s', 'format', 'png',
        '/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns',
        '--out', path
    ], capture_output=True)
    if path2x and size <= 1024:
        subprocess.run(['cp', path, path2x], capture_output=True)
" 2>/dev/null || true

    # Try to create .icns from the iconset
    if ls "$ICONSET_DIR"/*.png &>/dev/null; then
        iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES/AppIcon.icns" 2>/dev/null || true
    fi
    rm -rf "$(dirname "$ICONSET_DIR")"
fi

# Create entitlements
cat > "$CONTENTS/entitlements.plist" << ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENTITLEMENTS

# Codesign with entitlements if a signing identity is provided
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    echo "▸ Signing with identity: $SIGNING_IDENTITY"
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" \
        --entitlements "$CONTENTS/entitlements.plist" \
        "$APP_DIR"
    echo "▸ Verifying signature..."
    codesign --verify --deep --strict "$APP_DIR"
    echo "✓ Signature verified"
else
    echo "▸ Skipping codesign (set SIGNING_IDENTITY to sign)"
fi

echo ""
echo "✓ Built: $APP_DIR"
echo "  Version: $VERSION ($BUILD_NUMBER)"
echo "  Config:  $BUILD_CONFIG"

# Show size
APP_SIZE=$(du -sh "$APP_DIR" | awk '{print $1}')
echo "  Size:    $APP_SIZE"
echo ""
echo "To install: cp -r '$APP_DIR' /Applications/"
echo "To run:     open '$APP_DIR'"
