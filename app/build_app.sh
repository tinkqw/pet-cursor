#!/bin/bash
# 编译「宠物指针.app」（Intel + Apple 芯片通用），内置 ../skins/ 下的所有宠物文件夹，本地临时签名，打成 zip（含安装说明）。
# 宠物文件夹由 App 菜单「添加宠物…」或 tools/make_skin.py 生成。同事加自己的宠物不需要重打 App，用菜单「切换宠物 → 添加宠物…」。
# 用法：bash build_app.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$ROOT/dist"
APP="$OUT/宠物指针.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Skins"

# 1. 两种芯片各编一份再合并
for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" "$HERE/main.swift" "$HERE/SkinMaker.swift" -o "$TMP/app-$arch"
done
lipo -create "$TMP/app-arm64" "$TMP/app-x86_64" -output "$APP/Contents/MacOS/OrangeCatCursor"

# 2. 内置宠物 + App 图标（用橘猫「正常」图）
for d in "$ROOT"/skins/*/; do
  [ -f "$d/theme.cursor" ] && ditto "$d" "$APP/Contents/Resources/Skins/$(basename "$d")"
done
ditto "$HERE/pointers" "$APP/Contents/Resources/Pointers"   # 链接 / 张开爪 / 抓紧爪的爪子图，换皮时用
python3 - "$HERE/AppIcon-source.png" "$APP/Contents/Resources" "$TMP" <<'PY'
import sys, os, subprocess
from PIL import Image, ImageDraw
src, res, tmp = sys.argv[1:4]
iset = os.path.join(tmp, "AppIcon.iconset"); os.makedirs(iset)
base = Image.open(src).convert("RGBA")
for s in (16, 32, 128, 256, 512):
    for k in (1, 2):
        n = s * k
        mask = Image.new("L", (n, n)); ImageDraw.Draw(mask).rounded_rectangle([0, 0, n - 1, n - 1], radius=int(n * 0.22), fill=255)
        bg = Image.new("RGBA", (n, n)); bg.paste(Image.new("RGBA", (n, n), (255, 244, 228, 255)), (0, 0), mask)
        pad = int(n * 0.1); bg.alpha_composite(base.resize((n - 2 * pad,) * 2, Image.LANCZOS), (pad, pad))
        bg.save(os.path.join(iset, f"icon_{s}x{s}{'@2x' if k == 2 else ''}.png"))
subprocess.run(["iconutil", "-c", "icns", iset, "-o", os.path.join(res, "AppIcon.icns")], check=True)
PY

# 3. Info.plist：只在菜单栏出现（LSUIElement）
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>OrangeCatCursor</string>
  <key>CFBundleIdentifier</key><string>local.petcursor</string>
  <key>CFBundleName</key><string>宠物指针</string>
  <key>CFBundleDisplayName</key><string>宠物指针</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# 4. 本地临时签名（Apple 芯片上没有签名的程序不能运行；这不是开发者签名）
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

# 5. 压缩包：一个「宠物指针」文件夹，里面是 App + 安装说明
PKG="$TMP/pkg/宠物指针"; mkdir -p "$PKG"
ditto "$APP" "$PKG/宠物指针.app"
cp "$HERE/安装说明.txt" "$PKG/安装说明.txt"
rm -f "$OUT/PetCursor-Mac.zip"
(cd "$TMP/pkg" && ditto -c -k --norsrc --keepParent "宠物指针" "$OUT/PetCursor-Mac.zip")
echo "内置宠物：$(ls "$APP/Contents/Resources/Skins" | tr '\n' ' ')"
ls -la "$OUT"
