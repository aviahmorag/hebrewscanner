#!/bin/bash
#
# build_ios_libs.sh — Cross-compile Tesseract + dependencies as static libraries for iOS
#
# Produces TesseractIOS.xcframework in Frameworks/ with two slices:
#   - iphoneos (arm64)
#   - iphonesimulator (arm64)
#
# Usage:  ./scripts/build_ios_libs.sh
# Run from the HebrewScanner/ repo root (next to HebrewScanner.xcodeproj).
#
# Requirements: Xcode 26+, CMake, Ninja, pkg-config
#   brew install cmake ninja pkg-config
#
# Created by Aviah Morag in 2026.
#

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$REPO_ROOT/ios-build"
FRAMEWORKS_DIR="$REPO_ROOT/Frameworks"

IOS_DEPLOYMENT_TARGET="26.0"

# Library versions (match Homebrew)
LIBPNG_VER="1.6.50"
JPEGTURBO_VER="3.1.2"
GIFLIB_VER="5.2.2"
XZ_VER="5.8.1"
LZ4_VER="1.10.0"
ZSTD_VER="1.5.7"
LIBB2_VER="0.98.1"
WEBP_VER="1.6.0"
LIBTIFF_VER="4.7.1"
OPENJPEG_VER="2.5.4"
LIBARCHIVE_VER="3.8.1"
LEPTONICA_VER="1.86.0"
TESSERACT_VER="5.5.1"

# Source directory names after extraction
SRC_libpng="libpng-${LIBPNG_VER}"
SRC_jpegturbo="libjpeg-turbo-${JPEGTURBO_VER}"
SRC_giflib="giflib-${GIFLIB_VER}"
SRC_xz="xz-${XZ_VER}"
SRC_lz4="lz4-${LZ4_VER}"
SRC_zstd="zstd-${ZSTD_VER}"
SRC_libb2="libb2-${LIBB2_VER}"
SRC_webp="libwebp-${WEBP_VER}"
SRC_libtiff="tiff-${LIBTIFF_VER}"
SRC_openjpeg="openjpeg-${OPENJPEG_VER}"
SRC_libarchive="libarchive-${LIBARCHIVE_VER}"
SRC_leptonica="leptonica-${LEPTONICA_VER}"
SRC_tesseract="tesseract-${TESSERACT_VER}"

NPROC="$(sysctl -n hw.ncpu)"

# ─── Helper Functions ───────────────────────────────────────────────────

log() { printf "\033[1;34m==> %s\033[0m\n" "$*"; }
err() { printf "\033[1;31mERROR: %s\033[0m\n" "$*" >&2; exit 1; }

sdk_path() { xcrun --sdk "$1" --show-sdk-path; }

# Look up URL by library name
get_url() {
    case "$1" in
        libpng)     echo "https://download.sourceforge.net/libpng/libpng-${LIBPNG_VER}.tar.xz" ;;
        jpegturbo)  echo "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${JPEGTURBO_VER}/libjpeg-turbo-${JPEGTURBO_VER}.tar.gz" ;;
        giflib)     echo "https://download.sourceforge.net/giflib/giflib-${GIFLIB_VER}.tar.gz" ;;
        xz)         echo "https://github.com/tukaani-project/xz/releases/download/v${XZ_VER}/xz-${XZ_VER}.tar.xz" ;;
        lz4)        echo "https://github.com/lz4/lz4/releases/download/v${LZ4_VER}/lz4-${LZ4_VER}.tar.gz" ;;
        zstd)       echo "https://github.com/facebook/zstd/releases/download/v${ZSTD_VER}/zstd-${ZSTD_VER}.tar.gz" ;;
        libb2)      echo "https://github.com/BLAKE2/libb2/releases/download/v${LIBB2_VER}/libb2-${LIBB2_VER}.tar.gz" ;;
        webp)       echo "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${WEBP_VER}.tar.gz" ;;
        libtiff)    echo "https://download.osgeo.org/libtiff/tiff-${LIBTIFF_VER}.tar.xz" ;;
        openjpeg)   echo "https://github.com/uclouvain/openjpeg/archive/refs/tags/v${OPENJPEG_VER}.tar.gz" ;;
        libarchive) echo "https://github.com/libarchive/libarchive/releases/download/v${LIBARCHIVE_VER}/libarchive-${LIBARCHIVE_VER}.tar.xz" ;;
        leptonica)  echo "https://github.com/DanBloomberg/leptonica/releases/download/${LEPTONICA_VER}/leptonica-${LEPTONICA_VER}.tar.gz" ;;
        tesseract)  echo "https://github.com/tesseract-ocr/tesseract/archive/refs/tags/${TESSERACT_VER}.tar.gz" ;;
        *) err "Unknown library: $1" ;;
    esac
}

# Look up source directory name by library name
get_src_dir() {
    local varname="SRC_$1"
    echo "${!varname}"
}

# Common CMake flags for iOS cross-compilation
cmake_ios_flags() {
    local platform="$1"
    local install_prefix="$2"
    local sdk
    sdk="$(sdk_path "$platform")"

    cat <<EOF
-DCMAKE_SYSTEM_NAME=iOS
-DCMAKE_OSX_SYSROOT=$sdk
-DCMAKE_OSX_ARCHITECTURES=arm64
-DCMAKE_SYSTEM_PROCESSOR=aarch64
-DCMAKE_OSX_DEPLOYMENT_TARGET=$IOS_DEPLOYMENT_TARGET
-DCMAKE_INSTALL_PREFIX=$install_prefix
-DCMAKE_PREFIX_PATH=$install_prefix
-DBUILD_SHARED_LIBS=OFF
-DCMAKE_POSITION_INDEPENDENT_CODE=ON
EOF
}

download_and_extract() {
    local name="$1"
    local url
    url="$(get_url "$name")"
    local src_dir
    src_dir="$(get_src_dir "$name")"
    local tarball="$BUILD_ROOT/tarballs/$(basename "$url")"

    if [ -d "$BUILD_ROOT/src/$src_dir" ]; then
        return 0
    fi

    mkdir -p "$BUILD_ROOT/tarballs" "$BUILD_ROOT/src"

    if [ ! -f "$tarball" ]; then
        log "Downloading $name..."
        curl -L -o "$tarball" "$url"
    fi

    log "Extracting $name..."
    tar xf "$tarball" -C "$BUILD_ROOT/src"
}

# ─── Build Functions ────────────────────────────────────────────────────

build_libpng() {
    local platform="$1"
    local prefix="$BUILD_ROOT/install/$platform"
    local build_dir="$BUILD_ROOT/build/$platform/libpng"
    [ -f "$prefix/lib/libpng16.a" ] && return 0

    log "Building libpng for $platform..."
    mkdir -p "$build_dir"
    cmake -S "$BUILD_ROOT/src/$SRC_libpng" -B "$build_dir" -G Ninja \
        $(cmake_ios_flags "$platform" "$prefix") \
        -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF \
        -DPNG_EXECUTABLES=OFF -DPNG_FRAMEWORK=OFF
    cmake --build "$build_dir" -j "$NPROC"
    cmake --install "$build_dir"
}

build_jpegturbo() {
    local platform="$1"
    local prefix="$BUILD_ROOT/install/$platform"
    local build_dir="$BUILD_ROOT/build/$platform/jpegturbo"
    [ -f "$prefix/lib/libjpeg.a" ] && return 0

    log "Building libjpeg-turbo for $platform..."
    mkdir -p "$build_dir"
    cmake -S "$BUILD_ROOT/src/$SRC_jpegturbo" -B "$build_dir" -G Ninja \
        $(cmake_ios_flags "$platform" "$prefix") \
        -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
        -DWITH_TURBOJPEG=OFF
    cmake --build "$build_dir" -j "$NPROC"
    cmake --install "$build_dir"
}

build_giflib() {
    local platform="$1"
    local prefix="$BUILD_ROOT/install/$platform"
    [ -f "$prefix/lib/libgif.a" ] && return 0

    local sdk
    sdk="$(sdk_path "$platform")"
    local cc
    cc="$(xcrun --sdk "$platform" -f clang)"
    local src="$BUILD_ROOT/src/$SRC_giflib"

    log "Building giflib for $platform..."

    # giflib uses a simple Makefile; compile manually
    mkdir -p "$prefix/lib" "$prefix/include"
    local target_triple="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}"
    [ "$platform" = "iphonesimulator" ] && target_triple="${target_triple}-simulator"
    local cflags="-target $target_triple -isysroot $sdk"

    local obj_dir="$BUILD_ROOT/build/$platform/giflib"
    mkdir -p "$obj_dir"

    for f in dgif_lib egif_lib gif_err gif_font gif_hash gifalloc openbsd-reallocarray; do
        "$cc" $cflags -c "$src/$f.c" -o "$obj_dir/$f.o" -I"$src"
    done
    ar rcs "$prefix/lib/libgif.a" "$obj_dir"/*.o
    cp "$src/gif_lib.h" "$prefix/include/"
}

build_xz() {
    local platform="$1"
    local prefix="$BUILD_ROOT/install/$platform"
    local build_dir="$BUILD_ROOT/build/$platform/xz"
    [ -f "$prefix/lib/liblzma.a" ] && return 0

    log "Building xz (liblzma) for $platform..."
    mkdir -p "$build_dir"
    cmake -S "$BUILD_ROOT/src/$SRC_xz" -B "$build_dir" -G Ninja \
        $(cmake_ios_flags "$platform" "$prefix") \
        -DBUILD_SHARED_LIBS=OFF -DCREATE_XZ_SYMLINKS=OFF \
        -DCREATE_LZMA_SYMLINKS=OFF
    cmake --build "$build_dir" -j "$NPROC"
    cmake --install "$build_dir"
}

build_lz4() {
    local platform="$1"
    local prefix="$BUILD_ROOT/install/$platform"
    local build_dir="$BUILD_ROOT/build/$platform/lz4"
    [ -f "$prefix/lib/liblz4.a" ] && return 0

    log "Building lz4 for $platform..."
    mkdir -p "$build_dir"
    cmake -S "$BUILD_ROOT/src/$SRC_lz4/build/cmake" -B "$build_dir" -G Ninja \
        $(cmake_ios_flags "$platform" "$prefix") \
        -DLZ4_BUILD_CLI=OFF -DLZ4_BUILD_LEGACY_LZ4C=OFF \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON
    cmake --build "$build_dir" -j "$NPROC"
    cmake --install "$build_dir"
}

build_zstd() {
    local platform="$1"
    local prefix="$BUILD_ROOT/install/$platform"
    local build_dir="$BUILD_ROOT/build/$platform/zstd"
    [ -f "$prefix/lib/libzstd.a" ] && return 0

    log "Building zstd for $platform..."
    mkdir -p "$build_dir"
    cmake -S "$BUILD_ROOT/src/$SRC_zstd/build/cmake" -B "$build_dir" -G Ninja \
        $(cmake_ios_flags "$platform" "$prefix") \
        -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_SHARED=OFF \
        -DZSTD_BUILD_STATIC=ON -DZSTD_MULTITHREAD_SUPPORT=ON \
        -DZSTD_BUILD_TESTS=OFF
    cmake --build "$build_dir" -j "$NPROC"
    cmake --install "$build_dir"
}

build_libb2() {
    local platform="$1"
    local prefix="$BUILD_ROOT/install/$platform"
    [ -f "$prefix/lib/libb2.a" ] && return 0

    local sdk
    sdk="$(sdk_path "$platform")"
    local cc
    cc="$(xcrun --sdk "$platform" -f clang)"
    local src="$BUILD_ROOT/src/$SRC_libb2/src"

    log "Building libb2 for $platform..."

    # libb2 uses autotools; compile manually for simplicity
    mkdir -p "$prefix/lib" "$prefix/include"
    local target_triple="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}"
    [ "$platform" = "iphonesimulator" ] && target_triple="${target_triple}-simulator"
    local cflags="-target $target_triple -isysroot $sdk -DSUFFIX="

    local obj_dir="$BUILD_ROOT/build/$platform/libb2"
    mkdir -p "$obj_dir"

    # Create minimal config.h that autotools would normally generate
    cat > "$obj_dir/config.h" <<'CONFEOF'
#ifndef CONFIG_H
#define CONFIG_H
#define HAVE_STDINT_H 1
#define HAVE_STRING_H 1
#define HAVE_STDLIB_H 1
#endif
CONFEOF

    "$cc" $cflags -I"$obj_dir" -I"$src" -c "$src/blake2b-ref.c" -o "$obj_dir/blake2b-ref.o"
    "$cc" $cflags -I"$obj_dir" -I"$src" -c "$src/blake2s-ref.c" -o "$obj_dir/blake2s-ref.o"
    "$cc" $cflags -I"$obj_dir" -I"$src" -c "$src/blake2sp.c" -o "$obj_dir/blake2sp.o"
    "$cc" $cflags -I"$obj_dir" -I"$src" -c "$src/blake2bp.c" -o "$obj_dir/blake2bp.o"
    ar rcs "$prefix/lib/libb2.a" "$obj_dir"/*.o
    cp "$src/blake2.h" "$prefix/include/"
}

build_webp() {
    local platform="$1"
    local prefix="$BUILD_ROOT/install/$platform"
    local build_dir="$BUILD_ROOT/build/$platform/webp"
    [ -f "$prefix/lib/libwebp.a" ] && return 0

    log "Building libwebp for $platform..."
    mkdir -p "$build_dir"
    cmake -S "$BUILD_ROOT/src/$SRC_webp" -B "$build_dir" -G Ninja \
        $(cmake_ios_flags "$platform" "$prefix") \
        -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF \
        -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
        -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
        -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF \
        -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_WEBP_JS=OFF \
        -DPNG_LIBRARY="$prefix/lib/libpng16.a" \
        -DPNG_PNG_INCLUDE_DIR="$prefix/include" \
        -DJPEG_LIBRARY="$prefix/lib/libjpeg.a" \
        -DJPEG_INCLUDE_DIR="$prefix/include"
    cmake --build "$build_dir" -j "$NPROC"
    cmake --install "$build_dir"
}

build_libtiff() {
    local platform="$1"
    local prefix="$BUILD_ROOT/install/$platform"
    local build_dir="$BUILD_ROOT/build/$platform/libtiff"
    [ -f "$prefix/lib/libtiff.a" ] && return 0

    log "Building libtiff for $platform..."
    mkdir -p "$build_dir"
    cmake -S "$BUILD_ROOT/src/$SRC_libtiff" -B "$build_dir" -G Ninja \
        $(cmake_ios_flags "$platform" "$prefix") \
        -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF \
        -Dtiff-docs=OFF -DCMAKE_FIND_ROOT_PATH="$prefix" \
        -DJPEG_LIBRARY="$prefix/lib/libjpeg.a" \
        -DJPEG_INCLUDE_DIR="$prefix/include" \
        -DZLIB_LIBRARY="$(sdk_path "$platform")/usr/lib/libz.tbd" \
        -DZLIB_INCLUDE_DIR="$(sdk_path "$platform")/usr/include" \
        -Dlzma=ON -Dzstd=ON -Dwebp=ON -Djpeg=ON
    cmake --build "$build_dir" -j "$NPROC"
    cmake --install "$build_dir"

    # Patch TiffConfig.cmake — libtiff's TiffTargets.cmake references transitive
    # dep targets (ZLIB::ZLIB, JPEG::JPEG, liblzma::liblzma, ZSTD::ZSTD,
    # WebP::webp, CMath::CMath) but TiffConfig.cmake has "# TODO: import
    # dependencies" and never imports them. Patch it to do so.
    local tiff_config="$prefix/lib/cmake/tiff/TiffConfig.cmake"
    local sdk
    sdk="$(sdk_path "$platform")"
    cat > "$tiff_config" <<TIFFCFGEOF
include(CMakeFindDependencyMacro)

# Import transitive deps that TiffTargets.cmake references
find_dependency(ZLIB)
find_dependency(JPEG)
find_dependency(liblzma CONFIG)

# zstd installs targets as zstd::libzstd_static but tiff references ZSTD::ZSTD
if(NOT TARGET ZSTD::ZSTD)
    add_library(ZSTD::ZSTD STATIC IMPORTED)
    set_target_properties(ZSTD::ZSTD PROPERTIES
        IMPORTED_LOCATION "$prefix/lib/libzstd.a"
        INTERFACE_INCLUDE_DIRECTORIES "$prefix/include")
endif()

# WebP cmake config is in share/WebP/cmake/
find_dependency(WebP CONFIG)

# CMath::CMath is just -lm
if(NOT TARGET CMath::CMath)
    add_library(CMath::CMath INTERFACE IMPORTED)
    target_link_libraries(CMath::CMath INTERFACE m)
endif()

function(set_variable_from_rel_or_absolute_path var root rel_or_abs_path)
    if(IS_ABSOLUTE "\${rel_or_abs_path}")
        set(\${var} "\${rel_or_abs_path}" PARENT_SCOPE)
    else()
        set(\${var} "\${root}/\${rel_or_abs_path}" PARENT_SCOPE)
    endif()
endfunction()

get_filename_component(_DIR "\${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
get_filename_component(_ROOT "\${_DIR}/" ABSOLUTE)
set_variable_from_rel_or_absolute_path("TIFF_INCLUDE_DIR" "\${_ROOT}" "include")
set(TIFF_INCLUDE_DIRS \${TIFF_INCLUDE_DIR})
set(TIFF_LIBRARIES TIFF::tiff)

if(NOT TARGET TIFF::tiff)
    include("\${CMAKE_CURRENT_LIST_DIR}/TiffTargets.cmake")
endif()

unset(_ROOT)
unset(_DIR)
TIFFCFGEOF
}

build_openjpeg() {
    local platform="$1"
    local prefix="$BUILD_ROOT/install/$platform"
    local build_dir="$BUILD_ROOT/build/$platform/openjpeg"
    [ -f "$prefix/lib/libopenjp2.a" ] && return 0

    log "Building openjpeg for $platform..."
    mkdir -p "$build_dir"
    cmake -S "$BUILD_ROOT/src/$SRC_openjpeg" -B "$build_dir" -G Ninja \
        $(cmake_ios_flags "$platform" "$prefix") \
        -DBUILD_CODEC=OFF -DBUILD_TESTING=OFF \
        -DPNG_LIBRARY="$prefix/lib/libpng16.a" \
        -DPNG_PNG_INCLUDE_DIR="$prefix/include" \
        -DTIFF_LIBRARY="$prefix/lib/libtiff.a" \
        -DTIFF_INCLUDE_DIR="$prefix/include"
    cmake --build "$build_dir" -j "$NPROC"
    cmake --install "$build_dir"
}

build_libarchive() {
    local platform="$1"
    local prefix="$BUILD_ROOT/install/$platform"
    local build_dir="$BUILD_ROOT/build/$platform/libarchive"
    [ -f "$prefix/lib/libarchive.a" ] && return 0

    log "Building libarchive for $platform..."
    mkdir -p "$build_dir"
    cmake -S "$BUILD_ROOT/src/$SRC_libarchive" -B "$build_dir" -G Ninja \
        $(cmake_ios_flags "$platform" "$prefix") \
        -DENABLE_TEST=OFF -DENABLE_TAR=OFF -DENABLE_CPIO=OFF \
        -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_FIND_ROOT_PATH="$prefix" \
        -DZLIB_LIBRARY="$(sdk_path "$platform")/usr/lib/libz.tbd" \
        -DZLIB_INCLUDE_DIR="$(sdk_path "$platform")/usr/include"
    cmake --build "$build_dir" -j "$NPROC"
    cmake --install "$build_dir"
}

build_leptonica() {
    local platform="$1"
    local prefix="$BUILD_ROOT/install/$platform"
    local build_dir="$BUILD_ROOT/build/$platform/leptonica"
    [ -f "$prefix/lib/libleptonica.a" ] && return 0

    log "Building leptonica for $platform..."
    mkdir -p "$build_dir"

    local sdk
    sdk="$(sdk_path "$platform")"

    cmake -S "$BUILD_ROOT/src/$SRC_leptonica" -B "$build_dir" -G Ninja \
        $(cmake_ios_flags "$platform" "$prefix") \
        -DCMAKE_FIND_ROOT_PATH="$prefix;$sdk" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
        -DBUILD_PROG=OFF -DBUILD_TESTS=OFF \
        -DSW_BUILD=OFF \
        -DJPEG_LIBRARY="$prefix/lib/libjpeg.a" \
        -DJPEG_INCLUDE_DIR="$prefix/include" \
        -DPNG_LIBRARY="$prefix/lib/libpng16.a" \
        -DPNG_PNG_INCLUDE_DIR="$prefix/include" \
        -DGIF_LIBRARY="$prefix/lib/libgif.a" \
        -DGIF_INCLUDE_DIR="$prefix/include" \
        -DZLIB_LIBRARY="$sdk/usr/lib/libz.tbd" \
        -DZLIB_INCLUDE_DIR="$sdk/usr/include"
    cmake --build "$build_dir" -j "$NPROC"
    cmake --install "$build_dir"

    # Patch LeptonicaConfig.cmake to import transitive deps before loading targets.
    # LeptonicaTargets.cmake references ZLIB::ZLIB, JPEG::JPEG, liblzma::liblzma,
    # ZSTD::ZSTD, WebP::webp, CMath::CMath, openjp2 — these must exist when
    # a downstream project (tesseract) loads the leptonica config, including in
    # try_compile contexts.
    local lept_config="$prefix/lib/cmake/leptonica/LeptonicaConfig.cmake"
    local lept_config_orig
    lept_config_orig="$(cat "$lept_config")"
    cat > "$lept_config" <<LEPTCFGEOF
include(CMakeFindDependencyMacro)

# Import transitive deps referenced by LeptonicaTargets.cmake
find_dependency(ZLIB)
find_dependency(JPEG)
find_dependency(PNG)
find_dependency(GIF)
find_dependency(TIFF CONFIG)
find_dependency(OpenJPEG CONFIG)
find_dependency(WebP CONFIG)

# openjp2 target from OpenJPEG
if(NOT TARGET openjp2 AND TARGET openjp2_static)
    add_library(openjp2 ALIAS openjp2_static)
endif()

LEPTCFGEOF
    echo "$lept_config_orig" >> "$lept_config"
}

build_tesseract() {
    local platform="$1"
    local prefix="$BUILD_ROOT/install/$platform"
    local build_dir="$BUILD_ROOT/build/$platform/tesseract"
    [ -f "$prefix/lib/libtesseract.a" ] && return 0

    log "Building tesseract for $platform..."
    mkdir -p "$build_dir"
    cmake -S "$BUILD_ROOT/src/$SRC_tesseract" -B "$build_dir" -G Ninja \
        $(cmake_ios_flags "$platform" "$prefix") \
        -DCMAKE_FIND_ROOT_PATH="$prefix" \
        -DBUILD_TRAINING_TOOLS=OFF \
        -DDISABLE_CURL=ON \
        -DDISABLE_ARCHIVE=ON \
        -DGRAPHICS_DISABLED=ON \
        -DLeptonica_DIR="$prefix/lib/cmake/leptonica" \
        -DLEPT_TIFF_RESULT=0
    # Build only the library, not the CLI executable (can't run on host anyway)
    cmake --build "$build_dir" --target libtesseract -j "$NPROC"
    # Manual install: cmake --install would try to install the unbuilt executable
    mkdir -p "$prefix/lib" "$prefix/include/tesseract"
    cp "$build_dir/libtesseract.a" "$prefix/lib/"
    cp "$BUILD_ROOT/src/$SRC_tesseract/include/tesseract/"*.h "$prefix/include/tesseract/"
}

# ─── Main ───────────────────────────────────────────────────────────────

log "HebrewScanner iOS Static Library Builder"
log "Build root: $BUILD_ROOT"
log "Platforms: iphoneos iphonesimulator"
echo

# Check dependencies
for tool in cmake ninja pkg-config; do
    command -v "$tool" >/dev/null || err "$tool is required: brew install $tool"
done

# Download all sources
log "Downloading sources..."
for lib in libpng jpegturbo giflib xz lz4 zstd libb2 webp libtiff openjpeg leptonica tesseract; do
    download_and_extract "$lib"
done

# Build for each platform
for platform in iphoneos iphonesimulator; do
    log "━━━ Building for $platform ━━━"

    # Build in dependency order
    build_libpng "$platform"
    build_jpegturbo "$platform"
    build_giflib "$platform"
    build_xz "$platform"
    build_lz4 "$platform"
    build_zstd "$platform"
    build_libb2 "$platform"
    build_webp "$platform"
    build_libtiff "$platform"
    build_openjpeg "$platform"
    build_leptonica "$platform"
    build_tesseract "$platform"

    # Merge all static libraries into a single fat .a
    log "Merging static libraries for $platform..."
    local_prefix="$BUILD_ROOT/install/$platform"
    merged="$BUILD_ROOT/merged/$platform/libtesseract-ios.a"
    mkdir -p "$(dirname "$merged")"

    # Collect all .a files; webp may or may not produce libsharpyuv
    merge_libs=(
        "$local_prefix/lib/libtesseract.a"
        "$local_prefix/lib/libleptonica.a"
        "$local_prefix/lib/libopenjp2.a"
        "$local_prefix/lib/libtiff.a"
        "$local_prefix/lib/libwebp.a"
        "$local_prefix/lib/libzstd.a"
        "$local_prefix/lib/liblzma.a"
        "$local_prefix/lib/libgif.a"
        "$local_prefix/lib/libjpeg.a"
        "$local_prefix/lib/libpng16.a"
    )
    # Add optional libs if they exist
    for opt_lib in libsharpyuv.a libwebpdecoder.a libwebpdemux.a libwebpmux.a; do
        [ -f "$local_prefix/lib/$opt_lib" ] && merge_libs+=("$local_prefix/lib/$opt_lib")
    done
    libtool -static -o "$merged" "${merge_libs[@]}"

    log "Merged library: $(du -h "$merged" | cut -f1) → $merged"
done

# Create XCFramework
log "Creating TesseractIOS.xcframework..."
XCFW="$FRAMEWORKS_DIR/TesseractIOS.xcframework"
rm -rf "$XCFW"

# Collect headers for the framework
HEADERS_DIR="$BUILD_ROOT/headers"
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"

# Copy Tesseract and Leptonica public headers
cp -R "$BUILD_ROOT/install/iphoneos/include/tesseract" "$HEADERS_DIR/" 2>/dev/null || true
cp -R "$BUILD_ROOT/install/iphoneos/include/leptonica" "$HEADERS_DIR/" 2>/dev/null || true
# Also copy top-level headers (allheaders.h, etc.)
cp "$BUILD_ROOT/install/iphoneos/include/"*.h "$HEADERS_DIR/" 2>/dev/null || true

xcodebuild -create-xcframework \
    -library "$BUILD_ROOT/merged/iphoneos/libtesseract-ios.a" \
    -headers "$HEADERS_DIR" \
    -library "$BUILD_ROOT/merged/iphonesimulator/libtesseract-ios.a" \
    -headers "$HEADERS_DIR" \
    -output "$XCFW"

log "━━━ Done! ━━━"
log "XCFramework: $XCFW"
log ""
log "Verify with:"
log "  lipo -info $BUILD_ROOT/merged/iphoneos/libtesseract-ios.a"
log "  nm $BUILD_ROOT/merged/iphoneos/libtesseract-ios.a | grep TessBaseAPICreate"
log ""
log "Next: Add TesseractIOS.xcframework to the iOS target in Xcode."
