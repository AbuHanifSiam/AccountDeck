#!/bin/zsh
# Renders the README banner (light and dark) with headless Chrome at 2x.
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for mode in light dark; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=1280,727 --screenshot="$PWD/../banner-$mode.png" "file://$PWD/banner.html#$mode" 2>/dev/null
done
ls -la ../banner-*.png
