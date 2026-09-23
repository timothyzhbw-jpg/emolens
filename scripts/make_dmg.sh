#!/bin/bash
# 打包发布用的 DMG：通用版 EmoLens.app + 「应用程序」快捷方式，拖进去就装好。
# 产物在 build/EmoLens-<版本>.dmg。
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./scripts/build_app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/EmoLens.app/Contents/Info.plist)
DMG="build/EmoLens-$VERSION.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto build/EmoLens.app "$STAGE/EmoLens.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "EmoLens $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"
echo "✅ 已生成 $DMG（$(du -h "$DMG" | cut -f1)）"
shasum -a 256 "$DMG"
