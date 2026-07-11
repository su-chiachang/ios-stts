#!/usr/bin/env bash
# Build parakeet.cpp as macOS static libs (Metal embedded) and collect
# artifacts into stts/vendor/parakeet/. The static archives are linked
# directly into the app executable; ggml v0.13 stays private to it.
set -euo pipefail

STTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PARAKEET_SRC="${PARAKEET_SRC:-$(cd "$STTS_DIR/../../parakeet.cpp" && pwd)}"
BUILD_DIR="$STTS_DIR/build/parakeet"
VENDOR="$STTS_DIR/vendor/parakeet"

cmake -S "$PARAKEET_SRC" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DPARAKEET_SHARED=OFF \
  -DPARAKEET_BUILD_CLI=ON \
  -DPARAKEET_BUILD_SERVER=OFF \
  -DPARAKEET_GGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_BACKEND_DL=OFF \
  -DGGML_OPENMP=OFF
cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"

mkdir -p "$VENDOR/lib" "$VENDOR/include"
find "$BUILD_DIR" -name 'lib*.a' -exec cp -f {} "$VENDOR/lib/" \;
cp -f "$PARAKEET_SRC/include/parakeet_capi.h" "$VENDOR/include/"

SHIM="$STTS_DIR/Packages/NativeShims/Sources/CParakeet/include"
if [ -d "$SHIM" ]; then cp -f "$VENDOR/include/parakeet_capi.h" "$SHIM/"; fi

echo "== parakeet vendor artifacts =="
ls -la "$VENDOR/lib"
echo "CLI: $(find "$BUILD_DIR" -name 'parakeet-cli' -o -name 'cli' -type f -perm +111 | head -1)"
