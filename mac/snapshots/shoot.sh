#!/bin/zsh
# Takes the README screenshots: builds AccountDeck in screenshot mode, runs it against a
# demo home folder (made-up accounts, nothing of yours), and captures each page in light
# and dark. Output: docs/screenshots/*.png in the repository.
set -e
cd "$(dirname "$0")/.."
OUT=../docs/screenshots; mkdir -p $OUT
WORK=build/snapshots; mkdir -p $WORK
APP=$WORK/AccountDeckSnap.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
swiftc -O -swift-version 5 -parse-as-library -D SNAPSHOT -o $APP/Contents/MacOS/AccountDeckSnap Sources/*.swift snapshots/Snap.swift 2>/dev/null
cp Icon/AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.accountdeck.snapshot</string>
<key>CFBundleExecutable</key><string>AccountDeckSnap</string>
<key>CFBundleName</key><string>AccountDeck</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
python3 snapshots/make-demo-home.py $PWD/$WORK/demo-home
CFFIXED_USER_HOME=$PWD/$WORK/demo-home $APP/Contents/MacOS/AccountDeckSnap &
PID=$!
trap "kill $PID 2>/dev/null" EXIT
post() { swift snapshots/post.swift "$@"; }
win() {   # waits up to 10 s for the window to be on screen
  for i in {1..20}; do n=$(swift snapshots/windows.swift $PID "$1"); [ -n "$n" ] && { echo $n; return; }; sleep 0.5; done
  echo "window '$1' not found" >&2; return 1
}
sleep 4
for mode in light dark; do
  post snap.appearance $mode; post snap.size 1100,860; sleep 1.5
  post snap.select dashboard; sleep 1.5; screencapture -x -o -l $(win AccountDeck) $OUT/dashboard-$mode.png
  post snap.select claude-default; post snap.tab overview; sleep 2; screencapture -x -o -l $(win AccountDeck) $OUT/account-$mode.png
  post snap.tab chats; sleep 2; screencapture -x -o -l $(win AccountDeck) $OUT/chats-$mode.png
  post snap.select desktop-default; post snap.tab chats; sleep 2; screencapture -x -o -l $(win AccountDeck) $OUT/desktop-$mode.png
  post snap.menu; sleep 2; screencapture -x -o -l $(win "AccountDeck Menu") $OUT/menu-$mode.png
done
post snap.quit || true
echo "Screenshots in docs/screenshots"
