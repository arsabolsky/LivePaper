#!/bin/bash
# MARK: - [Phase 0] Updated for new directory layout after Phosphene port reorganisation.
# Source files are now split into three directories:
#   SakuraWallpaperCore/Sources/SakuraWallpaperCore/  — shared logic (app + extension)
#   App/                                               — app-only sources
#   Extension/                                         — extension-only sources (populated Phase 1+)

set -euo pipefail

APP_NAME="SakuraWallpaper"
EXT_NAME="SakuraWallpaperExtension"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
EXT_DIR="$APP_DIR/Contents/PlugIns/$EXT_NAME.appex"
APP_VERSION="2.0.0"
BUNDLE_ID="com.sakura.wallpaper"
EXT_BUNDLE_ID="com.sakura.wallpaper.extension"

# ---------------------------------------------------------------------------
# Core source files — compiled into both the app and (later) the extension.
# ---------------------------------------------------------------------------
CORE_SRCS=(
    SakuraWallpaperCore/Sources/SakuraWallpaperCore/Screen_Config.swift
    SakuraWallpaperCore/Sources/SakuraWallpaperCore/SettingsManager.swift
    SakuraWallpaperCore/Sources/SakuraWallpaperCore/MediaType.swift
    SakuraWallpaperCore/Sources/SakuraWallpaperCore/PlaylistBuilder.swift
)

# ---------------------------------------------------------------------------
# App source files — menu bar app (non-sandboxed, AppKit for now; SwiftUI in Phase 7).
# ---------------------------------------------------------------------------
APP_SRCS=(
    App/Localization.swift
    App/PerformanceMonitor.swift
    App/ScreenPlayer.swift
    App/WallpaperManager.swift
    App/MainWindowController.swift
    App/ThumbnailItem.swift
    App/ThumbnailProvider.swift
    App/AboutWindowController.swift
    App/AppDelegate.swift
    App/main.swift
)

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/PlugIns"

# ---------------------------------------------------------------------------
# Compile app
# ---------------------------------------------------------------------------
echo "Compiling app..."
swiftc -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
    "${CORE_SRCS[@]}" \
    "${APP_SRCS[@]}" \
    -framework Cocoa -framework AVKit -framework AVFoundation \
    -framework ServiceManagement -framework ImageIO -framework IOKit

# Copy resources and icon
cp -R App/Resources "$APP_DIR/Contents/"
cp App/AppIcon.icns "$APP_DIR/Contents/Resources/"

# Write app Info.plist
cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# ---------------------------------------------------------------------------
# Compile extension (Phase 1+: sources are added to Extension/ incrementally)
# ---------------------------------------------------------------------------
# Extension sources are populated starting in Phase 1. This block is a no-op
# until Extension/ contains .swift files; it will be uncommented and filled in
# as each phase adds source files to the Extension/ directory.
#
# EXT_SWIFT_SRCS=( $(find Extension -name '*.swift' | sort) )
# if [ "${#EXT_SWIFT_SRCS[@]}" -gt 0 ]; then
#     echo "Compiling extension..."
#     mkdir -p "$EXT_DIR/Contents/MacOS"
#
#     swiftc -o "$EXT_DIR/Contents/MacOS/$EXT_NAME" \
#         "${CORE_SRCS[@]}" \
#         "${EXT_SWIFT_SRCS[@]}" \
#         -framework Foundation -framework AVFoundation -framework CoreMedia \
#         -framework IOKit -framework QuartzCore
#
#     # Write extension Info.plist (NSExtension key registers the wallpaper extension point)
#     cat > "$EXT_DIR/Contents/Info.plist" << EXTPLIST
# <?xml version="1.0" encoding="UTF-8"?>
# <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
# <plist version="1.0">
# <dict>
#     <key>CFBundleExecutable</key>
#     <string>$EXT_NAME</string>
#     <key>CFBundleIdentifier</key>
#     <string>$EXT_BUNDLE_ID</string>
#     <key>CFBundleName</key>
#     <string>$EXT_NAME</string>
#     <key>CFBundleVersion</key>
#     <string>$APP_VERSION</string>
#     <key>CFBundleShortVersionString</key>
#     <string>$APP_VERSION</string>
#     <key>LSMinimumSystemVersion</key>
#     <string>26.0</string>
#     <key>NSExtension</key>
#     <dict>
#         <key>NSExtensionPointIdentifier</key>
#         <string>com.apple.wallpaper-extension</string>
#         <key>NSExtensionPrincipalClass</key>
#         <string>SakuraWallpaperExtension</string>
#     </dict>
# </dict>
# </plist>
# EXTPLIST
#
#     # Apply sandbox entitlements to extension
#     # The extension must run sandboxed; the app does not.
#     codesign --force --sign - \
#         --entitlements Extension/SakuraWallpaperExtension.entitlements \
#         "$EXT_DIR"
# fi

echo "Done! App: $APP_DIR"

# ---------------------------------------------------------------------------
# DMG packaging (pass 'dmg' as first argument)
# ---------------------------------------------------------------------------
if [ "${1:-}" = "dmg" ]; then
    echo "Creating DMG..."
    DMG_TMP="dmg_tmp"
    rm -rf "$DMG_TMP" "$APP_NAME.dmg"

    python3 -c "
from PIL import Image
img = Image.open('bg.jpg')
img = img.resize((500, 320), Image.LANCZOS)
img.save('bg.png', optimize=True)
"

    mkdir -p "$DMG_TMP"
    cp -R "$APP_DIR" "$DMG_TMP/"

    create-dmg \
      --volname "$APP_NAME" \
      --volicon "App/AppIcon.icns" \
      --background "bg.png" \
      --window-pos 100 100 \
      --window-size 500 320 \
      --icon-size 80 \
      --icon "$APP_NAME.app" 130 160 \
      --hide-extension "$APP_NAME.app" \
      --app-drop-link 360 160 \
      "$APP_NAME.dmg" \
      "$DMG_TMP" 2>&1 | grep -v "hdiutil does not support"

    rm -f bg.png
    rm -rf "$DMG_TMP"
    echo "Done! DMG: $APP_NAME.dmg"
fi
