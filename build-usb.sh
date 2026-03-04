#!/bin/bash
set -euo pipefail

export PATH=/opt/homebrew/bin:$PATH
cd ~/Projects/krak-whisper

CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' KrakWhisperApp.xcodeproj/project.pbxproj | tr -dc '0-9')
echo "📝 Build number: $CURRENT_BUILD"

echo "🔓 Unlocking keychain..."
security unlock-keychain -p 'iloveabigail!' ~/Library/Keychains/login.keychain-db
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k 'iloveabigail!' ~/Library/Keychains/login.keychain-db > /dev/null 2>&1

echo "📦 Archiving..."
ARCHIVE_PATH="/tmp/KrakWhisper-usb.xcarchive"
rm -rf "$ARCHIVE_PATH"

xcodebuild archive \
  -project KrakWhisperApp.xcodeproj \
  -scheme KrakWhisper \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=iOS" \
  DEVELOPMENT_TEAM=J4F36L43U9 \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  2>&1 | grep -E "error:|warning:|BUILD|ARCHIVE|Archive"

if [ ! -d "$ARCHIVE_PATH/Products/Applications/KrakWhisper.app" ]; then
  echo "❌ Archive failed - no .app found"
  exit 1
fi

# Verify keyboard extension is embedded
if [ -d "$ARCHIVE_PATH/Products/Applications/KrakWhisper.app/PlugIns/KrakWhisperKeyboard.appex" ]; then
  echo "✅ Archive created with keyboard extension"
else
  echo "⚠️ Archive created but keyboard extension missing!"
fi

echo "📱 Installing on iPhone..."
xcrun devicectl device install app \
  --device 4F649DC9-4842-50F3-A7ED-66C96418B673 \
  "$ARCHIVE_PATH/Products/Applications/KrakWhisper.app" 2>&1

echo "🎉 Done! App installed on iPhone."
