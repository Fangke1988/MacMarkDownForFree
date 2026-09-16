#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
npm run build:web
node scripts/collect-licenses.mjs
swift build -c release
swift scripts/make-icon.swift .build/icon
iconutil -c icns .build/icon/AppIcon.iconset -o .build/icon/AppIcon.icns
app_dir="$PWD/delivery/MarkDownEditor.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources/Web"
cp .build/release/MarkDownEditor "$app_dir/Contents/MacOS/MarkDownEditor"
cp -R web/dist/. "$app_dir/Contents/Resources/Web/"
cp scripts/Info.plist "$app_dir/Contents/Info.plist"
cp THIRD-PARTY-NOTICES.txt "$app_dir/Contents/Resources/"
cp .build/icon/AppIcon.icns "$app_dir/Contents/Resources/"
cp .build/icon/AppIcon.png delivery/AppIcon.png
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
