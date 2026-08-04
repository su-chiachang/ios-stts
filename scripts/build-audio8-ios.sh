#!/usr/bin/env bash
# Build Audio8 as iOS arm64 static archives per platform slice. The Audio8
# and GGML symbols are localized so the archive can coexist with Qwen and
# Parakeet's independent native runtimes in one iOS binary.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

IOS_DEPLOYMENT_TARGET="17.0"
PLATFORMS="${1:-iphoneos iphonesimulator}"
STTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUDIO8_SRC="${AUDIO8_SRC:-$STTS_DIR/../audio8.cpp}"
GGML_SRC="${AUDIO8_GGML_SOURCE_DIR:-$STTS_DIR/../audio.cpp/external/ggml}"
TOKENIZER_SRC="${AUDIO8_TOKENIZER_SOURCE_DIR:-$STTS_DIR/../audio.cpp}"
VENDOR="$STTS_DIR/vendor/audio8-ios"
ARCH="arm64"
JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || true)}"
JOBS="${JOBS:-4}"

for required in "$AUDIO8_SRC/CMakeLists.txt" "$AUDIO8_SRC/tools/audio8_c_consumer_smoke.c" \
  "$GGML_SRC/CMakeLists.txt" "$TOKENIZER_SRC/external/cJSON/cJSON.c"; do
  if [ ! -e "$required" ]; then
    echo "error: missing Audio8 build dependency: $required" >&2
    exit 1
  fi
done

mkdir -p "$VENDOR/include" "$STTS_DIR/Packages/NativeShims/Sources/CAudio8/include"

for PLATFORM in $PLATFORMS; do
  SLICE="$PLATFORM-$ARCH"
  BUILD_DIR="$STTS_DIR/build/audio8-ios/$SLICE"
  INSTALL_DIR="$BUILD_DIR/install"
  OUT_DIR="$VENDOR/$SLICE/lib"

  echo "== audio8: configuring $SLICE =="
  cmake -S "$AUDIO8_SRC" -B "$BUILD_DIR" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$PLATFORM" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DAUDIO8_BUILD_TESTS=ON \
    -DAUDIO8_BUILD_RUNTIME=ON \
    -DAUDIO8_ENABLE_METAL=ON \
    -DAUDIO8_ENABLE_INSTALL=ON \
    -DAUDIO8_GGML_SOURCE_DIR="$GGML_SRC" \
    -DAUDIO8_TOKENIZER_SOURCE_DIR="$TOKENIZER_SRC" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
  cmake --build "$BUILD_DIR" --target audio8-core \
    -j"$JOBS"
  cmake --install "$BUILD_DIR" --prefix "$INSTALL_DIR"

  cp -f "$INSTALL_DIR/include/audio8/audio8_runtime.h" \
    "$VENDOR/include/audio8_runtime.h"
  cp -f "$VENDOR/include/audio8_runtime.h" \
    "$STTS_DIR/Packages/NativeShims/Sources/CAudio8/include/audio8_runtime.h"

  case "$PLATFORM" in
    iphoneos) CLANG_TARGET="$ARCH-apple-ios$IOS_DEPLOYMENT_TARGET" ;;
    iphonesimulator) CLANG_TARGET="$ARCH-apple-ios$IOS_DEPLOYMENT_TARGET-simulator" ;;
    *) echo "error: unsupported iOS platform: $PLATFORM" >&2; exit 1 ;;
  esac
  IOS_SYSROOT="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"

  PUBLIC_SYMS="$BUILD_DIR/audio8_public_symbols.txt"
  nm -gU "$BUILD_DIR/libaudio8-core.a" \
    | rg -o '_audio8_[A-Za-z0-9_]+' \
    | sort -u > "$PUBLIC_SYMS" || true
  if [ ! -s "$PUBLIC_SYMS" ]; then
    echo "error: Audio8 public C symbols were not found in libaudio8-core.a" >&2
    exit 1
  fi

  ARCHIVES=(
    "$BUILD_DIR/libaudio8-core.a"
    "$BUILD_DIR/ggml/src/libggml.a"
    "$BUILD_DIR/ggml/src/libggml-base.a"
    "$BUILD_DIR/ggml/src/libggml-cpu.a"
    "$BUILD_DIR/ggml/src/ggml-blas/libggml-blas.a"
    "$BUILD_DIR/ggml/src/ggml-metal/libggml-metal.a"
  )
  for archive in "${ARCHIVES[@]}"; do
    if [ ! -f "$archive" ]; then
      echo "error: expected Audio8 archive is missing: $archive" >&2
      exit 1
    fi
  done

  case "$PLATFORM" in
    iphoneos)
      PLATFORM_VERSION_ARGS="ios $IOS_DEPLOYMENT_TARGET $IOS_DEPLOYMENT_TARGET"
      ;;
    iphonesimulator)
      PLATFORM_VERSION_ARGS="ios-simulator $IOS_DEPLOYMENT_TARGET $IOS_DEPLOYMENT_TARGET"
      ;;
    *) echo "error: unsupported iOS platform: $PLATFORM" >&2; exit 1 ;;
  esac

  LOCALIZED_O="$BUILD_DIR/audio8_ios_localized.o"
  # shellcheck disable=SC2086
  ld -r -arch "$ARCH" -platform_version $PLATFORM_VERSION_ARGS \
    -exported_symbols_list "$PUBLIC_SYMS" \
    "${ARCHIVES[@]}" \
    -o "$LOCALIZED_O"

  mkdir -p "$OUT_DIR"
  libtool -static -o "$OUT_DIR/libaudio8_ios.a" "$LOCALIZED_O"

  CONSUMER_OBJECT="$BUILD_DIR/audio8-c-consumer-smoke.o"
  CONSUMER_BINARY="$BUILD_DIR/audio8-c-consumer-smoke"
  xcrun --sdk "$PLATFORM" clang \
    -target "$CLANG_TARGET" \
    -isysroot "$IOS_SYSROOT" \
    -I "$VENDOR/include" \
    -c "$AUDIO8_SRC/tools/audio8_c_consumer_smoke.c" \
    -o "$CONSUMER_OBJECT"
  xcrun --sdk "$PLATFORM" clang \
    -target "$CLANG_TARGET" \
    -isysroot "$IOS_SYSROOT" \
    "$CONSUMER_OBJECT" \
    -L "$OUT_DIR" \
    -laudio8_ios \
    -lc++ \
    -framework Accelerate \
    -framework Metal \
    -framework Foundation \
    -o "$CONSUMER_BINARY"

  echo "== audio8: $SLICE artifact =="
  lipo -info "$OUT_DIR/libaudio8_ios.a"
done

echo "== audio8 iOS artifacts =="
ls -la "$VENDOR"/*/lib/libaudio8_ios.a
