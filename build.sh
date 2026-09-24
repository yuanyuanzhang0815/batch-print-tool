#!/bin/bash
# 批量打印工具 / BatchPrint — 构建脚本
# 要求：macOS 26 SDK（用了 .glassEffect / containerBackground 等新 API）
#
#   ./build.sh              构建到 dist/批量打印工具.app
#   ./build.sh --install    构建后装到 ~/Applications 并打开
#   ./build.sh --package    构建后额外产出 dist/BatchPrint-<版本>.dmg 与 .zip
#
# 可用环境变量覆盖：VERSION=1.4 BUILD_NUM=5 ARCH=x86_64 SDK=/path/to.sdk
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.3}"
BUILD_NUM="${BUILD_NUM:-4}"
NAME="批量打印工具"
BUNDLE="dist/$NAME.app"
DO_INSTALL=0
DO_PACKAGE=0
for a in "$@"; do
  case "$a" in
    --install) DO_INSTALL=1 ;;
    --package) DO_PACKAGE=1 ;;
    *) echo "未知参数：$a" >&2; exit 2 ;;
  esac
done

# SDK：优先 xcrun 探测，找不到再退回常见路径 —— 换机器 / 换 Xcode 版本不用改脚本
SDK="${SDK:-$(xcrun --show-sdk-path 2>/dev/null || true)}"
if [ -z "${SDK:-}" ] || [ ! -d "$SDK" ]; then
  for c in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do
    [ -d "$c" ] && SDK="$c" && break
  done
fi
if [ ! -d "${SDK:-}" ]; then
  echo "找不到 macOS SDK。请先安装 Xcode 或 Command Line Tools，或用 SDK=/path/to.sdk 指定。" >&2
  exit 1
fi

ARCH="${ARCH:-$(uname -m)}"          # Apple Silicon 走 arm64；Intel 机器可以 ARCH=x86_64
TARGET="${ARCH}-apple-macos26.0"
echo "SDK   : $SDK"
echo "目标  : $TARGET"
echo "版本  : $VERSION ($BUILD_NUM)"

mkdir -p build dist
swiftc -parse-as-library -O -sdk "$SDK" -target "$TARGET" \
      -o build/BatchPrint src/App.swift

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp build/BatchPrint "$BUNDLE/Contents/MacOS/BatchPrint"
echo "$VERSION" > "$BUNDLE/Contents/Resources/VERSION"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>BatchPrint</string>
  <key>CFBundleIdentifier</key><string>local.printtools.batchprint</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUM</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# ad-hoc 签名（没有开发者账号时的标准做法：能跑，但不做公证，首次打开需要用户确认一次）
codesign --force --deep -s - "$BUNDLE" >/dev/null 2>&1 || \
  echo "警告：ad-hoc 签名失败，应用仍可用，但首次打开可能需要在「系统设置 → 隐私与安全性」里放行"
echo "构建完成：$BUNDLE"

if [ "$DO_PACKAGE" = "1" ]; then
  # DMG：经典的拖进 Applications 布局
  STAGE="build/dmg"
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  cp -R "$BUNDLE" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "dist/BatchPrint-$VERSION.dmg"
  hdiutil create -volname "$NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
                 "dist/BatchPrint-$VERSION.dmg" >/dev/null
  # ZIP：给想直接拿 .app / 做自动化的人
  rm -f "dist/BatchPrint-$VERSION.zip"
  ditto -c -k --keepParent "$BUNDLE" "dist/BatchPrint-$VERSION.zip"
  echo "产物：dist/BatchPrint-$VERSION.dmg"
  echo "      dist/BatchPrint-$VERSION.zip"
  ( cd dist && shasum -a 256 "BatchPrint-$VERSION.dmg" "BatchPrint-$VERSION.zip" )
fi

if [ "$DO_INSTALL" = "1" ]; then
  rm -rf "$HOME/Applications/$NAME.app"
  mkdir -p "$HOME/Applications"
  cp -R "$BUNDLE" "$HOME/Applications/"
  echo "已安装到 ~/Applications/$NAME.app"
  open -a "$HOME/Applications/$NAME.app"
fi