#!/bin/sh
# Builds the GUI and wraps it into AppMemoryReport.app in the package root.
set -eu
cd "$(dirname "$0")/.."

# Both products: the CLI is also the root helper behind the GUI's lock button.
swift build -c release
bin=$(swift build -c release --show-bin-path)
app=AppMemoryReport.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/AppMemoryReport" "$bin/app-memory-report" "$app/Contents/MacOS/"

# Localizations go into the app itself (not as a nested SwiftPM resource bundle), so
# the main bundle, and with it AppKit's standard menus, knows them.
cp -R "$bin/app-memory-report_AppMemoryReport.bundle/Contents/Resources/"*.lproj "$app/Contents/Resources/"
display_name() {
    mkdir -p "$app/Contents/Resources/$1.lproj"
    printf '"CFBundleDisplayName" = "%s";\n"CFBundleName" = "%s";\n' "$2" "$2" \
        > "$app/Contents/Resources/$1.lproj/InfoPlist.strings"
}
display_name en "App Memory Report"
display_name de "Speicherverbrauch"

iconset=$(mktemp -d)/AppIcon.iconset
swift scripts/make-icon.swift "$iconset"
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$iconset"
rm -rf "$(dirname "$iconset")"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>AppMemoryReport</string>
    <key>CFBundleIdentifier</key><string>local.app-memory-report</string>
    <key>CFBundleName</key><string>App Memory Report</string>
    <key>CFBundleDisplayName</key><string>App Memory Report</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Nested code is signed before the bundle.
codesign --force --sign - "$app/Contents/MacOS/app-memory-report"
codesign --force --sign - "$app"
echo "Built $app"
