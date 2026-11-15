#!/bin/zsh
# Builds AccountDeck and packs it into dist/AccountDeck.dmg to share:
# the app, a shortcut to Applications, and how to open it the first time.
set -e
cd "$(dirname "$0")"
./build.sh
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/AccountDeck.app/Contents/Info.plist)
STAGE=build/dmg
rm -rf $STAGE dist && mkdir -p $STAGE dist
cp -R build/AccountDeck.app $STAGE/
ln -s /Applications $STAGE/Applications
cat > "$STAGE/How to open AccountDeck.txt" <<TXT
AccountDeck $VER — one menu bar app for your Claude, Claude Code, Codex and ChatGPT accounts.

1. Drag AccountDeck onto the Applications folder.
2. Open AccountDeck from Applications.
3. macOS says it can't check the app for malicious software, because it isn't
   from the App Store or a registered Apple developer. Click Done (not Move to Trash).
4. Open System Settings > Privacy & Security, scroll down, and click "Open Anyway"
   next to AccountDeck. Confirm with your password or Touch ID.
5. AccountDeck opens, and its mascot appears in the menu bar. You only do this once.

Everything AccountDeck keeps stays on your Mac (in ~/.accountdeck). It never reads
or sends your passwords.

Made by Nadim Sheikh — https://x.com/Nadim_404
TXT
hdiutil create -volname "AccountDeck $VER" -srcfolder $STAGE -ov -format UDZO -fs HFS+ "dist/AccountDeck-$VER.dmg" >/dev/null
rm -rf $STAGE
open ~/Applications/AccountDeck.app   # build.sh closed it; bring it back
echo "Made: dist/AccountDeck-$VER.dmg"
