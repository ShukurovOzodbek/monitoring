#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--install") ]]; then
    echo "Usage: $0 [--install]" >&2
    exit 2
fi

cd "$(dirname "$0")/.."
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app="build/Monitoring.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 644 Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
install -m 755 "$binary_dir/MonitoringApp" "$app/Contents/MacOS/Monitoring"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.ozodbek.monitoring</string>
    <key>CFBundleName</key>
    <string>Monitoring</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleExecutable</key>
    <string>Monitoring</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$app"
if [[ ${1:-} == "--install" ]]; then
    ditto "$app" /Applications/Monitoring.app
    echo "Installed /Applications/Monitoring.app"
else
    echo "Created $app"
fi
