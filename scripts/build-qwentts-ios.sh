#!/usr/bin/env bash
# Build qwentts.cpp's qwen-core static library for iOS per platform slice
# (iphoneos/iphonesimulator, arm64), then localize every ggml/gguf symbol to
# file-local scope the same way build-parakeet-ios.sh does, so the two
# engines' differently-versioned ggml copies can coexist statically linked
# into one iOS binary. Unlike the macOS build (build-qwentts-macos.sh), this
# does NOT build QWEN_SHARED — the macOS dylib split exists only to dodge
# the same symbol collision that `ld -r` localization solves here directly,
# so iOS stays fully static (see progress.md for the collision background).
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

IOS_DEPLOYMENT_TARGET="17.0"
PLATFORMS="${1:-iphoneos iphonesimulator}"

STTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

QWEN_SRC="$STTS_DIR/third_party/qwentts.cpp"
if [ ! -d "$QWEN_SRC" ]; then
  git clone --recursive https://github.com/ServeurpersoCom/qwentts.cpp "$QWEN_SRC"
fi
VENDOR="$STTS_DIR/vendor/qwentts-ios"

mkdir -p "$VENDOR/include"
cp -f "$QWEN_SRC/src/qwen.h" "$VENDOR/include/"
SHIM="$STTS_DIR/Packages/NativeShims/Sources/CQwenTTS/include"
if [ -d "$SHIM" ]; then cp -f "$VENDOR/include/qwen.h" "$SHIM/"; fi

for PLATFORM in $PLATFORMS; do
  ARCH=arm64
  SLICE="$PLATFORM-$ARCH"
  BUILD_DIR="$STTS_DIR/build/qwentts-ios/$SLICE"
  OUT_DIR="$VENDOR/$SLICE/lib"

  echo "== qwentts: configuring $SLICE =="
  cmake -S "$QWEN_SRC" -B "$BUILD_DIR" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$PLATFORM" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DQWEN_SHARED=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF
  cmake --build "$BUILD_DIR" --target qwen-core -j"$(sysctl -n hw.ncpu)"

  echo "== qwentts: localizing ggml/gguf symbols for $SLICE =="
  PUBLIC_SYMS="$BUILD_DIR/qwen_public_symbols.txt"
  nm -gU "$BUILD_DIR/libqwen-core.a" | grep -o '_qt_[A-Za-z0-9_]*' | sort -u > "$PUBLIC_SYMS"

  case "$PLATFORM" in
    iphoneos) MIN_MAX="ios $IOS_DEPLOYMENT_TARGET $IOS_DEPLOYMENT_TARGET" ;;
    iphonesimulator) MIN_MAX="ios-simulator $IOS_DEPLOYMENT_TARGET $IOS_DEPLOYMENT_TARGET" ;;
  esac

  LOCALIZED_O="$BUILD_DIR/qwen_ios_localized.o"
  # shellcheck disable=SC2086
  ld -r -arch "$ARCH" -platform_version $MIN_MAX \
    -exported_symbols_list "$PUBLIC_SYMS" \
    "$BUILD_DIR/libqwen-core.a" \
    "$BUILD_DIR/ggml/src/libggml.a" \
    "$BUILD_DIR/ggml/src/libggml-base.a" \
    "$BUILD_DIR/ggml/src/libggml-cpu.a" \
    "$BUILD_DIR/ggml/src/ggml-metal/libggml-metal.a" \
    "$BUILD_DIR/ggml/src/ggml-blas/libggml-blas.a" \
    -o "$LOCALIZED_O"

  mkdir -p "$OUT_DIR"
  libtool -static -o "$OUT_DIR/libqwen_ios.a" "$LOCALIZED_O"
  echo "== qwentts: $SLICE artifact =="
  lipo -info "$OUT_DIR/libqwen_ios.a"
done

echo "== qwentts-ios vendor artifacts =="
find "$VENDOR" -name '*.a' -exec ls -la {} \;
