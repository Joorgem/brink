#!/bin/bash
# Brink — tek komutla derle, .app ve .dmg üret.
# Gereksinim: macOS 13+ ve Xcode Command Line Tools (xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Brink"
BUNDLE_ID="com.semihtali.brink"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Swift derleniyor (release, arm64 + x86_64)..."
# Two single-arch builds + lipo: works with Command Line Tools alone
# (`--arch a --arch b` needs full Xcode's xcbuild).
# Each binary is copied out right after its build: newer SwiftPM (swift-build
# backend) puts every triple in the same .build/out/Products/Release folder.
SLICES=".build/slices"
mkdir -p "$SLICES"
for TRIPLE in arm64-apple-macosx x86_64-apple-macosx; do
    swift build -c release --triple "$TRIPLE"
    BIN="$(swift build -c release --triple "$TRIPLE" --show-bin-path)/$APP_NAME"
    cp "$BIN" "$SLICES/$TRIPLE"
done

echo "==> .app paketi oluşturuluyor..."
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$SLICES/arm64-apple-macosx" "$SLICES/x86_64-apple-macosx" -output "$APP/Contents/MacOS/$APP_NAME"
# Resources (logos, <lang>.lproj) go straight into Contents/Resources and are read
# via Bundle.main — the standard macOS layout. (SwiftPM's Bundle.module accessor
# only knows the build machine's path and the .app root; see issue #8.)
cp -R "Sources/${APP_NAME}/Resources/." "$APP/Contents/Resources/"
cp "assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>9</string>
    <key>CFBundleShortVersionString</key><string>0.6.0</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>tr</string><string>de</string><string>fr</string><string>es</string><string>pt-BR</string><string>it</string><string>ja</string><string>zh-Hans</string><string>ko</string></array>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><false/>
    </dict>
</dict>
</plist>
PLIST

echo "==> Ad-hoc imzalanıyor..."
codesign --force --sign - "$APP"

echo "==> DMG oluşturuluyor..."
DMG_ROOT="$DIST/dmgroot"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DIST/$APP_NAME.dmg" >/dev/null
rm -rf "$DMG_ROOT"

echo ""
echo "✅ Bitti!"
echo "   Uygulama : $APP"
echo "   DMG      : $DIST/$APP_NAME.dmg"
echo ""
echo "Çalıştırmak için:  open $APP"
echo "veya DMG'yi açıp Brink'ı Applications klasörüne sürükleyin."
