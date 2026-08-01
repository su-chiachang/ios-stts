#!/usr/bin/env bash
# Build parakeet.cpp as iOS static libs (Metal embedded) per platform slice
# (iphoneos/iphonesimulator, arm64), then localize every ggml/gguf symbol to
# file-local scope via `ld -r -exported_symbols_list` so this archive can be
# statically linked alongside qwentts's own (differently-versioned) ggml
# copy in one iOS binary without duplicate-symbol errors. See
# build-qwentts-ios.sh for the qwentts side of the same trick, and
# progress.md for why the two engines can't just share one ggml copy.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

IOS_DEPLOYMENT_TARGET="17.0"
PLATFORMS="${1:-iphoneos iphonesimulator}"

STTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [ ! -d "$STTS_DIR/third_party/parakeet.cpp" ]; then
  git clone --recursive https://github.com/mudler/parakeet.cpp "$STTS_DIR/third_party/parakeet.cpp"
fi
PARAKEET_SRC="${PARAKEET_SRC:-$(cd "$STTS_DIR/third_party/parakeet.cpp" && pwd)}"
VENDOR="$STTS_DIR/vendor/parakeet-ios"

mkdir -p "$VENDOR/include"
cp -f "$PARAKEET_SRC/include/parakeet_capi.h" "$VENDOR/include/"
SHIM="$STTS_DIR/Packages/NativeShims/Sources/CParakeet/include"
mkdir -p "$SHIM"
cp -f "$VENDOR/include/parakeet_capi.h" "$SHIM/"

for PLATFORM in $PLATFORMS; do
  ARCH=arm64
  SLICE="$PLATFORM-$ARCH"
  BUILD_DIR="$STTS_DIR/build/parakeet-ios/$SLICE"
  OUT_DIR="$VENDOR/$SLICE/lib"

  echo "== parakeet: configuring $SLICE =="
  cmake -S "$PARAKEET_SRC" -B "$BUILD_DIR" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$PLATFORM" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DPARAKEET_SHARED=OFF \
    -DPARAKEET_BUILD_CLI=OFF \
    -DPARAKEET_BUILD_SERVER=OFF \
    -DPARAKEET_GGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_BACKEND_DL=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF
  cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"

  echo "== parakeet: localizing ggml/gguf symbols for $SLICE =="
  PUBLIC_SYMS="$BUILD_DIR/parakeet_public_symbols.txt"
  nm -gU "$BUILD_DIR/libparakeet.a" | grep -o '_parakeet_capi_[A-Za-z0-9_]*' | sort -u > "$PUBLIC_SYMS"

  case "$PLATFORM" in
    iphoneos) MIN_MAX="ios $IOS_DEPLOYMENT_TARGET $IOS_DEPLOYMENT_TARGET" ;;
    iphonesimulator) MIN_MAX="ios-simulator $IOS_DEPLOYMENT_TARGET $IOS_DEPLOYMENT_TARGET" ;;
  esac

  LOCALIZED_O="$BUILD_DIR/parakeet_ios_localized.o"
  # shellcheck disable=SC2086
  ld -r -arch "$ARCH" -platform_version $MIN_MAX \
    -exported_symbols_list "$PUBLIC_SYMS" \
    "$BUILD_DIR/libparakeet.a" \
    "$BUILD_DIR/third_party/ggml/src/libggml.a" \
    "$BUILD_DIR/third_party/ggml/src/libggml-base.a" \
    "$BUILD_DIR/third_party/ggml/src/libggml-cpu.a" \
    "$BUILD_DIR/third_party/ggml/src/ggml-metal/libggml-metal.a" \
    "$BUILD_DIR/third_party/ggml/src/ggml-blas/libggml-blas.a" \
    -o "$LOCALIZED_O"

  mkdir -p "$OUT_DIR"
  libtool -static -o "$OUT_DIR/libparakeet_ios.a" "$LOCALIZED_O"
  echo "== parakeet: $SLICE artifact =="
  lipo -info "$OUT_DIR/libparakeet_ios.a"
done

echo "== parakeet-ios vendor artifacts =="
find "$VENDOR" -name '*.a' -exec ls -la {} \;
