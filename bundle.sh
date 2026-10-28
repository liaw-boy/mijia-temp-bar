#!/bin/zsh
set -e
cd "$(dirname "$0")"

echo "==> 正在生成 AppIcon.icns..."
mkdir -p /tmp/clang_cache
swift generate_icon.swift AppIcon.iconset
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset

echo "==> 正在編譯 MijiaTempBar (Swift Native)..."
swiftc -O -module-cache-path /tmp/clang_cache \
    -framework AppKit \
    -framework CoreBluetooth \
    -framework UserNotifications \
    -framework CoreLocation \
    -framework Network \
    -framework CoreWLAN \
    Sources/*.swift \
    -o MijiaTempBar

APP="MijiaTempBar.app"
echo "==> 正在專案目錄打包 $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp MijiaTempBar "$APP/Contents/MacOS/"
cp AppIcon.icns "$APP/Contents/Resources/"
if [ -f "Resources/device.png" ]; then
    cp Resources/device.png "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MijiaTempBar</string>
    <key>CFBundleDisplayName</key>
    <string>米家溫濕度狀態列</string>
    <key>CFBundleIdentifier</key>
    <string>com.boywei.MijiaTempBar</string>
    <key>CFBundleExecutable</key>
    <string>MijiaTempBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.7.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>需要使用藍牙連線並讀取米家溫濕度計 2 的即時溫濕度與電量數據。</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>需要使用藍牙連線並讀取米家溫濕度計 2 的即時溫濕度與電量數據。</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>用於建立居家大範圍地理圍欄，在您離開家時徹底關閉藍牙輪詢以節省筆電電力，回到家時自動喚醒連線。</string>
    <key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
    <string>用於建立居家大範圍地理圍欄，在您離開家時徹底關閉藍牙輪詢以節省筆電電力，回到家時自動喚醒連線。</string>
</dict>
</plist>
EOF

echo "==> 正在進行本機簽名 (codesign)..."
codesign --force --deep --sign - "$APP"

echo "==> 打包完成！應用程式位置: $(pwd)/$APP"
