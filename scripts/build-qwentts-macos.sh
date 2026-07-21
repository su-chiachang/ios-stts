#!/usr/bin/env bash
# Build qwentts.cpp as a shared library with Metal, then collect its dylib
# closure for embedding in the macOS app bundle.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

STTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QWEN_SRC="$STTS_DIR/third_party/qwentts.cpp"
VENDOR="$STTS_DIR/vendor/qwentts"
BUILD_DIR="$STTS_DIR/.build/qwentts"

QWEN_SRC="$STTS_DIR/third_party/qwentts.cpp"
if [ ! -d "$QWEN_SRC" ]; then
  git clone --recursive https://github.com/ServeurpersoCom/qwentts.cpp "$QWEN_SRC"
fi


cmake -S "$QWEN_SRC" -B "$BUILD_DIR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DBUILD_SHARED_LIBS=ON \
  -DQWEN_SHARED=ON
cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"

rm -rf "$VENDOR/lib" "$VENDOR/include"
mkdir -p "$VENDOR/lib" "$VENDOR/include"
strip_version() { echo "$1" | sed -E 's/(\.[0-9]+)+\.dylib$/.dylib/'; }
for src in "$BUILD_DIR"/libqwen*.dylib "$BUILD_DIR"/libggml*.dylib; do
  [ -e "$src" ] || continue
  [ -L "$src" ] && continue
  cp -f "$src" "$VENDOR/lib/$(strip_version "$(basename "$src")")"
done
cp -f "$QWEN_SRC/src/qwen.h" "$VENDOR/include/"
cp -f "$QWEN_SRC/src/qwen.h" "$STTS_DIR/Packages/NativeShims/Sources/CQwenTTS/include/qwen.h"

for lib in "$VENDOR/lib"/*.dylib; do
  [ -e "$lib" ] || continue
  base="$(basename "$lib")"
  install_name_tool -id "@rpath/$base" "$lib"
  otool -L "$lib" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    case "$dep" in
      *libggml*.dylib|*libqwen*.dylib)
        flat="$(strip_version "$(basename "$dep")")"
        [ "$dep" = "@rpath/$flat" ] || install_name_tool -change "$dep" "@rpath/$flat" "$lib"
        ;;
    esac
  done
  codesign -f -s - "$lib" >/dev/null 2>&1 || true
done

test -f "$VENDOR/lib/libqwen.dylib"
echo "== qwentts vendor artifacts =="
ls -la "$VENDOR/lib"
