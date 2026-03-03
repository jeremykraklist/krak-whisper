#!/bin/bash
set -euo pipefail

export PATH="/opt/homebrew/bin:$PATH"
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

cd ~/Projects/krak-whisper

# Auto-increment build number
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' KrakWhisperApp.xcodeproj/project.pbxproj | tr -dc '0-9')
NEW_BUILD=$((CURRENT_BUILD + 1))
echo "📝 Incrementing build: $CURRENT_BUILD → $NEW_BUILD"
sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" KrakWhisperApp.xcodeproj/project.pbxproj

echo "🔓 Unlocking keychain..."
security unlock-keychain -p "iloveabigail!" ~/Library/Keychains/login.keychain-db
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "iloveabigail!" ~/Library/Keychains/login.keychain-db > /dev/null 2>&1

echo "🧹 Cleaning build..."
xcodebuild clean -project KrakWhisperApp.xcodeproj -scheme KrakWhisper -quiet 2>/dev/null || true

echo "📦 Archiving KrakWhisper (build $NEW_BUILD)..."
ARCHIVE_PATH="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/KrakWhisper-build$NEW_BUILD.xcarchive"

xcodebuild archive \
  -project KrakWhisperApp.xcodeproj \
  -scheme KrakWhisper \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=iOS" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM=J4F36L43U9 \
  -allowProvisioningUpdates 2>&1 | grep -E '^\*\*|error:|warning:.*sign' || true

echo "✅ Archive created: $ARCHIVE_PATH"

# ──── FIX: Manually embed + sign keyboard extension ────
# xcodebuild's codesign for extensions fails with errSecInternalComponent via SSH.
# The extension builds fine but goes to UninstalledProducts without valid signature.
# We fix this by manually copying, signing, and embedding it post-archive.

APP_DIR="$ARCHIVE_PATH/Products/Applications/KrakWhisper.app"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/KrakWhisperApp-geoeyyhfhzncclazshdkwswtbinz"
APPEX_SRC="$DERIVED/Build/Intermediates.noindex/ArchiveIntermediates/KrakWhisper/IntermediateBuildFilesPath/UninstalledProducts/iphoneos/KrakWhisperKeyboard.appex"
KB_ENTITLEMENTS="$DERIVED/Build/Intermediates.noindex/ArchiveIntermediates/KrakWhisper/IntermediateBuildFilesPath/KrakWhisperApp.build/Release-iphoneos/KrakWhisperKeyboard.build/KrakWhisperKeyboard.appex.xcent"
APP_ENTITLEMENTS="$DERIVED/Build/Intermediates.noindex/ArchiveIntermediates/KrakWhisper/IntermediateBuildFilesPath/KrakWhisperApp.build/Release-iphoneos/KrakWhisper.build/KrakWhisper.app.xcent"
SIGNING_ID="5C57F976E9705F9FDCEAAEA087D11445CAA258DA"

if [ -d "$APPEX_SRC" ] && [ ! -d "$APP_DIR/PlugIns/KrakWhisperKeyboard.appex" ]; then
    echo "🔧 Fixing keyboard extension (errSecInternalComponent workaround)..."
    
    # Re-unlock keychain (may have been locked during build)
    security unlock-keychain -p "iloveabigail!" ~/Library/Keychains/login.keychain-db
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "iloveabigail!" ~/Library/Keychains/login.keychain-db > /dev/null 2>&1
    
    mkdir -p "$APP_DIR/PlugIns"
    cp -R "$APPEX_SRC" "$APP_DIR/PlugIns/"
    
    # Sign extension
    /usr/bin/codesign --force --sign "$SIGNING_ID" \
        --entitlements "$KB_ENTITLEMENTS" \
        --generate-entitlement-der \
        "$APP_DIR/PlugIns/KrakWhisperKeyboard.appex"
    
    # Re-sign main app (required after modifying bundle contents)
    /usr/bin/codesign --force --sign "$SIGNING_ID" \
        --entitlements "$APP_ENTITLEMENTS" \
        --generate-entitlement-der \
        "$APP_DIR"
    
    echo "✅ Keyboard extension embedded and signed"
else
    if [ -d "$APP_DIR/PlugIns/KrakWhisperKeyboard.appex" ]; then
        echo "✅ Keyboard extension already in archive"
    else
        echo "⚠️ Keyboard extension not found in build products"
    fi
fi

echo "🚀 Exporting for TestFlight..."
EXPORT_PATH="$HOME/Projects/krak-whisper/build"
mkdir -p "$EXPORT_PATH"

cat > /tmp/ExportOptions.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>J4F36L43U9</string>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>destination</key>
    <string>upload</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist /tmp/ExportOptions.plist \
  -exportPath "$EXPORT_PATH" \
  -allowProvisioningUpdates 2>&1 | tail -10

echo "🎉 TestFlight build $NEW_BUILD uploaded!"
