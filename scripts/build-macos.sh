#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== Self tests ==="
bash scripts/test-core.sh

echo "=== Metadata capability guards ==="
grep -q '"hif"' Sources/MetadataReader.swift || { echo 'HIF 지원 목록 누락'; exit 1; }
grep -q '"arw"' Sources/MetadataReader.swift || { echo 'ARW 지원 목록 누락'; exit 1; }
grep -q 'QuickTimeUTC=0' Sources/MetadataReader.swift || { echo '영상 시간대 정책 누락'; exit 1; }
grep -q 'MetadataReader.exifArguments' Sources/PersistentExifSession.swift || { echo '공통 메타데이터 태그 정책 누락'; exit 1; }
grep -q 'CREATE TABLE IF NOT EXISTS pairs' Sources/HistoryStore.swift || { echo '복원 동반 파일 기록 누락'; exit 1; }

echo "=== Pinned ExifTool 13.64, SHA-256 validated ==="
EXIF_VERSION="13.64"
EXIF_SHA="dcb9f6be1f6705ee826a92d1522e3fec1d0b3749cdc061b03c46873d5fe204fc"
mkdir -p build/deps
curl --fail --location --retry 5 --retry-delay 3 \
    --output "build/deps/Image-ExifTool-${EXIF_VERSION}.tar.gz" \
    "https://sourceforge.net/projects/exiftool/files/Image-ExifTool-${EXIF_VERSION}.tar.gz/download"
printf '%s  %s\n' "$EXIF_SHA" "build/deps/Image-ExifTool-${EXIF_VERSION}.tar.gz" | shasum -a 256 -c -
tar -xzf "build/deps/Image-ExifTool-${EXIF_VERSION}.tar.gz" -C build/deps
EXIF_ROOT="$PWD/build/deps/Image-ExifTool-${EXIF_VERSION}"
test -f "$EXIF_ROOT/exiftool"
test -d "$EXIF_ROOT/lib/Image/ExifTool"
/usr/bin/perl "$EXIF_ROOT/exiftool" -ver | grep -Fx "$EXIF_VERSION"

echo "=== Universal macOS app compile ==="
APP="$PWD/dist/00CaptureDate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/exiftool" build/arch
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for ARCH in arm64 x86_64; do
    echo "Compiling $ARCH for macOS 13+"
    xcrun swiftc -swift-version 5 -parse-as-library -O \
        -target "${ARCH}-apple-macos13.0" -sdk "$SDK" \
        Sources/*.swift -framework SwiftUI -framework AppKit -framework CryptoKit -lsqlite3 \
        -o "build/arch/00CaptureDate-${ARCH}"
done
lipo -create "build/arch/00CaptureDate-arm64" "build/arch/00CaptureDate-x86_64" \
     -output "$APP/Contents/MacOS/00CaptureDate"
lipo -info "$APP/Contents/MacOS/00CaptureDate"

cp "$EXIF_ROOT/exiftool" "$APP/Contents/Resources/exiftool/exiftool"
cp -R "$EXIF_ROOT/lib" "$APP/Contents/Resources/exiftool/lib"
cp "$EXIF_ROOT/README" "$APP/Contents/Resources/exiftool/README.ExifTool.txt"
if [ -f "$EXIF_ROOT/Changes" ]; then
    cp "$EXIF_ROOT/Changes" "$APP/Contents/Resources/exiftool/Changes.ExifTool.txt"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>00CaptureDate</string>
<key>CFBundleIdentifier</key><string>win.yespick.00CaptureDate</string>
<key>CFBundleName</key><string>00CaptureDate</string>
<key>CFBundleDisplayName</key><string>00CaptureDate</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
/usr/bin/perl "$APP/Contents/Resources/exiftool/exiftool" -ver | grep -Fx "$EXIF_VERSION"

# Ad-hoc signing is for integrity only; it is NOT Apple Developer ID notarization.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/00CaptureDate-macOS-universal.zip"
shasum -a 256 "dist/00CaptureDate-macOS-universal.zip" > "dist/SHA256SUMS.txt"
echo "BUILD SUCCESS: dist/00CaptureDate-macOS-universal.zip"
