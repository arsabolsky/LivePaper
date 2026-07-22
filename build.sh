#!/bin/bash

APP_NAME="LivePaper"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
APP_VERSION="1.1.0"

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
    PausePolicy.swift \
    PauseEvaluator.swift \
    PauseCoordinator.swift \
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
