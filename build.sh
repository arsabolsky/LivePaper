#!/bin/bash

APP_NAME="LivePaper"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
APP_VERSION="1.0.1"

# Deployment target — MUST be passed to swiftc via -target. Without it, swiftc
# derives the Mach-O LC_BUILD_VERSION `minos` from the host toolchain, which on
# recent systems resolves ABOVE the running OS (e.g. minos 28.0 on a macOS 26/27
# host). A binary whose `minos` exceeds the current OS is rejected at launch with
# "not compatible with this version of macOS" — LSMinimumSystemVersion in
# Info.plist does NOT set minos. Pin it to match LSMinimumSystemVersion below.
DEPLOYMENT_TARGET="12.0"
SWIFT_TARGET="$(uname -m)-apple-macos$DEPLOYMENT_TARGET"

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Compile
echo "Compiling..."
swiftc -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
    -target "$SWIFT_TARGET" \
    Screen_Config.swift \
    SettingsManager.swift \
    MediaType.swift \
    PlaylistBuilder.swift \
    Localization.swift \
    PerformanceMonitor.swift \
    ScreenPlayer.swift \
    WallpaperManager.swift \
    MainWindowController.swift \
    ThumbnailItem.swift \
    ThumbnailProvider.swift \
    AboutWindowController.swift \
    AppDelegate.swift \
    main.swift \
    -framework Cocoa -framework AVKit -framework AVFoundation -framework ServiceManagement -framework ImageIO -framework IOKit

# Copy resources
cp -R Resources "$APP_DIR/Contents/"

# Copy icon
cp AppIcon.icns "$APP_DIR/Contents/Resources/"

# Write Info.plist
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
    <string>com.arsabolsky.livepaper</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

echo "Done! App: $APP_DIR"

# Package DMG (pass 'dmg' as the first argument)
if [ "$1" = "dmg" ]; then
    echo "Creating DMG..."
    DMG_TMP="dmg_tmp"
    rm -rf "$DMG_TMP" "$APP_NAME.dmg"

    # Compress the background image
    python3 -c "
from PIL import Image
img = Image.open('bg.jpg')
img = img.resize((500, 320), Image.LANCZOS)
img.save('bg.png', optimize=True)
"

    # Prepare contents
    mkdir -p "$DMG_TMP"
    cp -R "$APP_DIR" "$DMG_TMP/"

    # Package with create-dmg (requires: brew install create-dmg)
    create-dmg \
      --volname "$APP_NAME" \
      --volicon "AppIcon.icns" \
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
