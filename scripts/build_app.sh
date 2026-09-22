#!/bin/bash
# 构建 EmoLens.app：release 编译 → 组装 .app → ad-hoc 签名。产物在 build/EmoLens.app。
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.2.0"
APP="build/EmoLens.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/EmoLens "$APP/Contents/MacOS/EmoLens"
cp -R presets "$APP/Contents/Resources/presets"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.emolens.EmoLens</string>
    <key>CFBundleName</key><string>EmoLens</string>
    <key>CFBundleDisplayName</key><string>EmoLens 情绪透镜</string>
    <key>CFBundleExecutable</key><string>EmoLens</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 签名：有稳定证书时用它（屏幕录制权限在重新构建后仍然有效）；没有就退回 ad-hoc。
# 创建证书：钥匙串访问 → 证书助理 → 创建证书…，名称 "EmoLens Local"，类型「代码签名」。
IDENTITY="${EMOLENS_SIGN_IDENTITY:-EmoLens Local}"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "✅ 已生成 $APP（签名：$IDENTITY）"
else
    codesign --force --deep --sign - "$APP"
    echo "✅ 已生成 $APP（ad-hoc 签名）"
    echo "⚠️  ad-hoc 签名每次构建都会变，macOS 会要求重新授予屏幕录制权限。"
    echo "   创建一次「$IDENTITY」代码签名证书即可避免，见 README。"
fi
