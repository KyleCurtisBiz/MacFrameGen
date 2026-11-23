#!/bin/zsh
# Builds build/MacFrameGen.app from the Swift package.
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  also copy it to /Applications (replacing any copy there)
#
# Signing. macOS ties the Camera, Microphone and Screen Recording permissions to the app's signature. By default
# the app gets an ad-hoc signature, which changes with every build, so macOS asks for the permissions again
# after each rebuild. To keep them, sign with a certificate of your own:
#   CODESIGN_IDENTITY="<name or SHA-1 of a code-signing certificate in your keychain>" scripts/build-app.sh
# or put that line (without the script name) in a file called .local.env next to Package.swift.
set -e
cd "$(dirname "$0")/.."
[ -f .local.env ] && source .local.env
IDENTITY="${CODESIGN_IDENTITY:--}"
BUNDLE_ID="${BUNDLE_ID:-local.macframegen}"
VERSION="0.1.0"

swift build -c release
APP=build/MacFrameGen.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacFrameGen "$APP/Contents/MacOS/MacFrameGen"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>MacFrameGen</string>
<key>CFBundleExecutable</key><string>MacFrameGen</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSCameraUsageDescription</key><string>MacFrameGen reads video from your HDMI capture card.</string>
<key>NSMicrophoneUsageDescription</key><string>MacFrameGen plays the game sound coming from your HDMI capture card.</string>
</dict></plist>
PL
codesign --force --sign "$IDENTITY" "$APP"
echo "built $APP (signed: $([ "$IDENTITY" = "-" ] && echo ad-hoc || echo with your certificate))"

if [ "$1" = "--install" ]; then
  # Copy beside the old one, then swap, so a copy that is running is never half-written.
  rm -rf /Applications/.MacFrameGen.new.app; ditto "$APP" /Applications/.MacFrameGen.new.app
  rm -rf /Applications/.MacFrameGen.old.app
  [ -d /Applications/MacFrameGen.app ] && mv /Applications/MacFrameGen.app /Applications/.MacFrameGen.old.app
  mv /Applications/.MacFrameGen.new.app /Applications/MacFrameGen.app; rm -rf /Applications/.MacFrameGen.old.app
  # Leave exactly one copy on the Mac, so opening "MacFrameGen" can never start a stale build from this folder.
  rm -rf build
  echo "installed /Applications/MacFrameGen.app (quit and reopen it if it was running)"
fi
