#!/bin/bash
# 构建分架构（Apple Silicon / Intel）的可分发 .app，并用 ditto 打成保留代码签名的 zip。
# 产物：dist/release/LynxiTime-<version>-mac-arm64.zip
#       dist/release/LynxiTime-<version>-mac-x86_64.zip
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="LynxiTime"
BUNDLE_ID="com.lynxi.LynxiTime"
VERSION="1.0.0"
BUILD="1"
REL_DIR="dist/release"

build_arch() {
  local arch="$1"   # arm64 | x86_64
  local label="$2"  # arm64 | x86_64（文件名用）

  echo "==> swift build (release, ${arch})…"
  swift build -c release --arch "$arch"
  local bin_path
  bin_path="$(swift build -c release --arch "$arch" --show-bin-path)/${APP_NAME}"

  local app_bundle="${REL_DIR}/${arch}/${APP_NAME}.app"
  echo "==> assembling ${app_bundle}…"
  rm -rf "${REL_DIR}/${arch}"
  mkdir -p "${app_bundle}/Contents/MacOS" "${app_bundle}/Contents/Resources"

  cp "$bin_path" "${app_bundle}/Contents/MacOS/${APP_NAME}"
  cp -R Sources/LynxiTime/Resources/*.lproj "${app_bundle}/Contents/Resources/"
  cp Assets/AppIcon.icns "${app_bundle}/Contents/Resources/AppIcon.icns"

  cat > "${app_bundle}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
    </array>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>LynxiTime</string>
</dict>
</plist>
PLIST

  echo -n "APPL????" > "${app_bundle}/Contents/PkgInfo"

  echo "==> ad-hoc codesign (${arch})…"
  codesign --force --sign - "$app_bundle"

  # ditto 打 zip 保留符号链接与代码签名；--keepParent 让解压得到 LynxiTime.app
  local zip="${REL_DIR}/${APP_NAME}-${VERSION}-mac-${label}.zip"
  rm -f "$zip"
  ditto -c -k --keepParent "$app_bundle" "$zip"
  echo "✅ $zip"
  file "${app_bundle}/Contents/MacOS/${APP_NAME}" | sed 's/^/   /'
}

rm -rf "$REL_DIR"
mkdir -p "$REL_DIR"
build_arch arm64 arm64
build_arch x86_64 x86_64

echo ""
echo "🎉 打包完成："
ls -lh "$REL_DIR"/*.zip
