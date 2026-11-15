#!/bin/zsh
# Renders the README banner (light and dark) with headless Chrome at 2x.
cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for mode in light dark; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
    --window-size=1280,727 --screenshot="$PWD/../banner-$mode.png" "file://$PWD/banner.html#$mode" 2>/dev/null
done
ls -la ../banner-*.png
# Download buttons (cropped to the button).
for b in mac win; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --default-background-color=00000000 \
    --window-size=330,159 --screenshot="$PWD/../button-$b.png" "file://$PWD/buttons.html#$b" 2>/dev/null
  python3 -c "import sys;from PIL import Image;p=sys.argv[1];im=Image.open(p);im.crop(im.getbbox()).save(p)" "$PWD/../button-$b.png"
done
