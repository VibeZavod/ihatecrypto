"""The DMG window's background (660×400, @1x and @2x): the app's dotted canvas, its name, an orange arrow from where
the app sits to where Applications sits, and what to do in English and Russian. release.sh places the icons on it.
Run from App/:  python3 Tools/dmg/make-background.py   → Tools/dmg/background.tiff (both sizes in one file)."""
import os, subprocess
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, "..", "..", "Sources", "IhatecryptoApp", "Fonts")
W, H = 660, 400   # the bottom stays empty: a Finder with the tab bar on shows ≈ 36 points less
APP, APPS, ICON_Y = 170, 490, 170          # icon centers, as release.sh sets them (window points)
CANVAS, DOTS, INK, MUTED, ORANGE = (0xEE, 0xF0, 0xF3), (0xD3, 0xD7, 0xDC), (0x11, 0x11, 0x11), (0x6B, 0x70, 0x7A), (0xFF, 0x7A, 0x2F)

def draw(scale):
    img = Image.new("RGB", (W * scale, H * scale), CANVAS)
    d = ImageDraw.Draw(img)
    for y in range(11, H, 22):                                   # the canvas's dot grid
        for x in range(11, W, 22):
            r = 1.1 * scale
            d.ellipse((x * scale - r, y * scale - r, x * scale + r, y * scale + r), fill=DOTS)
    # The app's own faces and weights: the wordmark is DynaPuff Bold (Font.brand), the interface Onest (Font.ui).
    def face(file, size, weight):
        f = ImageFont.truetype(os.path.join(FONTS, file), size * scale)
        f.set_variation_by_name(weight)
        return f
    logo, text, small = face("DynaPuff.ttf", 32, "Bold"), face("Onest.ttf", 15, "Medium"), face("Onest.ttf", 13, "Regular")
    d.text((W * scale / 2, 40 * scale), "ihatecrypto", font=logo, fill=INK, anchor="mm")
    # The arrow between the two icons: a shaft and a head, rounded.
    x0, x1, y = (APP + 78) * scale, (APPS - 78) * scale, ICON_Y * scale
    d.line((x0, y, x1 - 10 * scale, y), fill=ORANGE, width=6 * scale)
    d.polygon([(x1, y), (x1 - 20 * scale, y - 13 * scale), (x1 - 20 * scale, y + 13 * scale)], fill=ORANGE)
    d.ellipse((x0 - 3 * scale, y - 3 * scale, x0 + 3 * scale, y + 3 * scale), fill=ORANGE)
    d.text((W * scale / 2, 290 * scale), "Drag ihatecrypto to Applications", font=text, fill=INK, anchor="mm")
    d.text((W * scale / 2, 312 * scale), "Перетащите ihatecrypto в Applications", font=small, fill=MUTED, anchor="mm")
    return img

one, two = os.path.join(HERE, "background.png"), os.path.join(HERE, "background@2x.png")
draw(1).save(one, dpi=(72, 72))
draw(2).save(two, dpi=(144, 144))
subprocess.run(["tiffutil", "-cathidpicheck", one, two, "-out", os.path.join(HERE, "background.tiff")], check=True, capture_output=True)
os.remove(one); os.remove(two)
print("Tools/dmg/background.tiff")
