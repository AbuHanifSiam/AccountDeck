#!/bin/zsh
# Builds AccountDeck.app and installs it into ~/Applications.
set -e
cd "$(dirname "$0")"
APP=build/AccountDeck.app
rm -rf build && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
# One app for both Apple silicon and Intel Macs.
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target $ARCH-apple-macos14.0 \
    -o build/AccountDeck-$ARCH Sources/*.swift
done
lipo -create build/AccountDeck-arm64 build/AccountDeck-x86_64 -output $APP/Contents/MacOS/AccountDeck
rm build/AccountDeck-arm64 build/AccountDeck-x86_64
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>AccountDeck</string>
  <key>CFBundleDisplayName</key><string>AccountDeck</string>
  <key>CFBundleIdentifier</key><string>local.accountdeck</string>
  <key>CFBundleExecutable</key><string>AccountDeck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.5</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>NSHumanReadableCopyright</key><string>Made by Nadim Sheikh</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
cp Icon/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
codesign --force --sign - $APP
mkdir -p ~/Applications
pkill -x AccountDeck 2>/dev/null || true
rm -rf ~/Applications/AccountDeck.app && cp -R $APP ~/Applications/
echo "Installed: ~/Applications/AccountDeck.app"
