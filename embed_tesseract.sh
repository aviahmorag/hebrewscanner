#!/bin/bash
set -e

# Use Xcode's environment variables when available
if [ -n "$BUILT_PRODUCTS_DIR" ]; then
    APP_BUILD_PATH="$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME"
else
    # Fallback for manual runs
    APP_NAME="Ayin"
    APP_BUILD_PATH="build/Build/Products/Debug/${APP_NAME}.app"
fi

FRAMEWORKS_SRC="$SRCROOT/Frameworks"
RESOURCES_SRC="$SRCROOT/Resources"

echo "Embedding Tesseract into ${APP_BUILD_PATH}..."
echo "SRCROOT: $SRCROOT"
echo "BUILT_PRODUCTS_DIR: $BUILT_PRODUCTS_DIR"

# 1. Copy dylibs
mkdir -p "${APP_BUILD_PATH}/Contents/Frameworks"
cp -v ${FRAMEWORKS_SRC}/*.dylib "${APP_BUILD_PATH}/Contents/Frameworks/"

# 2. Copy tessdata
mkdir -p "${APP_BUILD_PATH}/Contents/Resources/tessdata"
cp -v ${RESOURCES_SRC}/tessdata/* "${APP_BUILD_PATH}/Contents/Resources/tessdata/"

# 3. Strip stale Homebrew signatures so install_name_tool doesn't warn
echo "Stripping existing signatures..."
for dylib in "${APP_BUILD_PATH}/Contents/Frameworks/"*.dylib; do
    chmod +w "$dylib"
    codesign --remove-signature "$dylib"
done

# 4. Fix install names
echo "Patching library paths..."
for dylib in "${APP_BUILD_PATH}/Contents/Frameworks/"*.dylib; do
    install_name_tool -id @rpath/$(basename "$dylib") "$dylib"
done
install_name_tool -change /opt/homebrew/opt/leptonica/lib/libleptonica.6.dylib @rpath/libleptonica.6.dylib "${APP_BUILD_PATH}/Contents/Frameworks/libtesseract.5.dylib"

# 5. Sign all frameworks
echo "Signing frameworks..."
for dylib in "${APP_BUILD_PATH}/Contents/Frameworks/"*.dylib; do
    codesign --force --sign - "$dylib"
done

echo "✅ Done embedding Tesseract!"
