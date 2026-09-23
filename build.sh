#!/bin/bash
# 批量打印工具 · 构建脚本
# 需要 macOS 26 SDK（使用了 .glassEffect / containerBackground 等新 API）
set -e
cd "$(dirname "$0")"
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
APP="$HOME/Applications/批量打印工具.app"
VERSION=1.2
swiftc -parse-as-library -O -sdk "$SDK" -target arm64-apple-macos26.0 \
      -o build/BatchPrint src/App.swift
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/BatchPrint "$APP/Contents/MacOS/BatchPrint"
echo "$VERSION" > "$APP/Contents/Resources/VERSION"
# plist 已存在时同步版本号，避免「应用是新的、版本号是旧的」
if [ -f "$APP/Contents/Info.plist" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
                          -c "Set :CFBundleVersion 3" \
                          "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f "$APP/Contents/Info.plist" ] || cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>批量打印工具</string>
  <key>CFBundleDisplayName</key><string>批量打印工具</string>
  <key>CFBundleExecutable</key><string>BatchPrint</string>
  <key>CFBundleIdentifier</key><string>local.printtools.batchprint.v2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1
echo "构建完成: $APP (v$VERSION)"
