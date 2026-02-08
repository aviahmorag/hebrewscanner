#!/bin/bash
set -e

# Use Xcode's environment variables when available
if [ -n "$BUILT_PRODUCTS_DIR" ]; then
    APP_BUILD_PATH="$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME"
else
    # Fallback for manual runs
    APP_NAME="HebrewScanner"
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

# 2. Copy tesseract binary + tessdata
mkdir -p "${APP_BUILD_PATH}/Contents/Resources/tessdata"
cp -v "${RESOURCES_SRC}/tesseract" "${APP_BUILD_PATH}/Contents/Resources/"
cp -v ${RESOURCES_SRC}/tessdata/* "${APP_BUILD_PATH}/Contents/Resources/tessdata/"

# Make tesseract executable
chmod +x "${APP_BUILD_PATH}/Contents/Resources/tesseract"

# 3. Fix install names for libtesseract
echo "Patching libtesseract to use relative paths..."
chmod +w "${APP_BUILD_PATH}/Contents/Frameworks/libtesseract.5.dylib"
install_name_tool -change /opt/homebrew/opt/leptonica/lib/libleptonica.6.dylib @rpath/libleptonica.6.dylib "${APP_BUILD_PATH}/Contents/Frameworks/libtesseract.5.dylib"

# 4. Fix install names for leptonica (and others)
for dylib in "${APP_BUILD_PATH}/Contents/Frameworks/"*.dylib; do
    echo "Fixing $dylib..."
    chmod +w "$dylib"
    install_name_tool -id @rpath/$(basename "$dylib") "$dylib"
done

# 5. Fix the tesseract binary to find the dylibs
echo "Patching tesseract binary..."
install_name_tool -add_rpath @loader_path/../Frameworks "${APP_BUILD_PATH}/Contents/Resources/tesseract"

# 6. Sign all frameworks
echo "Signing frameworks..."
for dylib in "${APP_BUILD_PATH}/Contents/Frameworks/"*.dylib; do
    codesign --force --sign - "$dylib"
done

# 7. Sign the tesseract binary
echo "Signing tesseract binary..."
codesign --force --sign - "${APP_BUILD_PATH}/Contents/Resources/tesseract"

echo "✅ Done embedding Tesseract!"
