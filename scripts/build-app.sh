#!/bin/zsh
#
#  build-app.sh
#  Disk Health
#
#  Copyright © 2026 Advandz Technologies, LLC.
#

# Builds a universal (Apple Silicon + Intel) Disk Health.app bundle and its release disk image.
#   ./scripts/build-app.sh            → build/Disk Health.app and build/Disk-Health-<version>.dmg
#   ./scripts/build-app.sh --open     → build and launch
#   CONFIG=debug ./scripts/build-app.sh
#
# The version: set VERSION below for a release. VERSION=1.2.3 in the environment overrides it for one
# build (handy for testing the updater with a "newer" copy).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
APP_NAME="Disk Health"
EXECUTABLE="DiskHealth"
BUNDLE_ID="io.diskhealth.monitor"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
COPYRIGHT="Copyright © 2026 Advandz Technologies, LLC."
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"

echo "▸ Building $EXECUTABLE ($CONFIG, arm64 + x86_64)…"
if swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product "$EXECUTABLE"; then
  BIN="$(swift build -c "$CONFIG" --arch arm64 --arch x86_64 --show-bin-path)/$EXECUTABLE"
else
  echo "▸ Multi-arch build failed; building each architecture and merging with lipo…"
  swift build -c "$CONFIG" --arch arm64 --product "$EXECUTABLE"
  swift build -c "$CONFIG" --arch x86_64 --product "$EXECUTABLE"
  mkdir -p "$OUT"
  lipo -create \
    "$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/$EXECUTABLE" \
    "$(swift build -c "$CONFIG" --arch x86_64 --show-bin-path)/$EXECUTABLE" \
    -output "$OUT/$EXECUTABLE.universal"
  BIN="$OUT/$EXECUTABLE.universal"
fi

if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  echo "▸ Rendering fallback app icon…"
  "$ROOT/scripts/make-icon.sh"
fi

echo "▸ Assembling $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"

# App icon. Resources/AppIcon.icon is an Icon Composer document (Liquid Glass, with Default, Dark,
# Clear and Tinted appearances). Xcode's actool compiles it into Assets.car, which macOS 26 uses.
# The static AppIcon.icns rendered from it covers macOS 14–15 and builds without Xcode.
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
ICON_NAME_KEY=""
if xcrun --find actool >/dev/null 2>&1; then
  echo "▸ Compiling Liquid Glass icon…"
  ICON_OBJ="$(mktemp -d)"
  if xcrun actool "$ROOT/Resources/AppIcon.icon" \
      --compile "$APP/Contents/Resources" \
      --platform macosx --target-device mac --minimum-deployment-target 14.0 \
      --app-icon AppIcon --include-all-app-icons \
      --output-partial-info-plist "$ICON_OBJ/AppIcon-partial.plist" \
      --errors --warnings >/dev/null; then
    ICON_NAME_KEY="<key>CFBundleIconName</key><string>AppIcon</string>"
  else
    echo "  actool failed; using the static AppIcon.icns" >&2
  fi
  rm -rf "$ICON_OBJ"
else
  echo "▸ Using the static icon (install Xcode 26 to compile the Liquid Glass AppIcon.icon)"
fi

# Localizations: the String Catalog is compiled into <lang>.lproj folders of the main bundle, which is
# where both the SwiftUI views and DiskHealthCore look strings up (Bundle.main).
echo "▸ Compiling localizations…"
xcrun xcstringstool compile "$ROOT/Resources/Localizable.xcstrings" --output-directory "$APP/Contents/Resources" >/dev/null
LOCALIZATIONS=""
for dir in "$APP/Contents/Resources/"*.lproj(N); do
  LOCALIZATIONS+="<string>${${dir:t}%.lproj}</string>"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  $ICON_NAME_KEY
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array>$LOCALIZATIONS</array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
</dict>
</plist>
PLIST

# Ad-hoc signature (not sandboxed: S.M.A.R.T. user clients are unavailable inside the App Sandbox).
codesign --force --deep --sign - --options runtime --timestamp=none "$APP" >/dev/null

echo "▸ Architectures: $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")"
echo "▸ Languages: $(cd "$APP/Contents/Resources" && ls -d *.lproj | sed 's/\.lproj//' | tr '\n' ' ')"
echo "✓ Built: $APP"

# Release disk image: the app and a link to /Applications. Attach it to the GitHub release; the
# in-app updater downloads it from there.
DMG="$OUT/Disk-Health-$VERSION.dmg"
echo "▸ Packing ${DMG#$ROOT/}…"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE:?}"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "✓ Packed: $DMG"

if [[ "${1:-}" == "--open" ]]; then
  open "$APP"
fi
