#!/usr/bin/env bash
# Build qwen3-tts.cpp per its documented flow (prebuilt ggml dylibs + shared
# libqwen3tts) and collect the dylib set into stts/vendor/qwen3tts/lib for
# embedding in the app bundle. Install names are normalized to @rpath so
# Xcode's Embed & Sign + LD_RUNPATH_SEARCH_PATHS resolve them.
set -euo pipefail

STTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QWEN_SRC="$(cd "$STTS_DIR/third_party/qwen3-tts.cpp" && pwd)"
VENDOR="$STTS_DIR/vendor/qwen3tts"

# 1) ggml (Metal + embedded shader library, so no default.metallib to bundle)
cmake -S "$QWEN_SRC/ggml" -B "$QWEN_SRC/ggml/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON
cmake --build "$QWEN_SRC/ggml/build" -j"$(sysctl -n hw.ncpu)"

# 2) qwen3-tts (expects prebuilt ggml under ggml/build/src)
cmake -S "$QWEN_SRC" -B "$QWEN_SRC/build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build "$QWEN_SRC/build" -j"$(sysctl -n hw.ncpu)"

# 3) collect dylibs + header, flattening versioned names (libggml-base.0.dylib
#    → libggml-base.dylib) so the app can link -lqwen3tts and embed plain files
#    without symlink chains.
strip_version() { echo "$1" | sed -E 's/(\.[0-9]+)+\.dylib$/.dylib/'; }

rm -rf "$VENDOR/lib"
mkdir -p "$VENDOR/lib" "$VENDOR/include"
for src in "$QWEN_SRC/build"/libqwen3tts*.dylib \
           $(find "$QWEN_SRC/ggml/build/src" -name 'libggml*.dylib'); do
  [ -L "$src" ] && continue
  cp -f "$src" "$VENDOR/lib/$(strip_version "$(basename "$src")")"
done
cp -f "$QWEN_SRC/src/qwen3tts_c_api.h" "$VENDOR/include/"

SHIM="$STTS_DIR/Packages/NativeShims/Sources/CQwen3TTS/include"
if [ -d "$SHIM" ]; then cp -f "$VENDOR/include/qwen3tts_c_api.h" "$SHIM/"; fi

# 4) normalize: set each id to @rpath/<flat-name>; rewrite every internal dep
#    (versioned @rpath or absolute build path) to the flat @rpath name.
for lib in "$VENDOR/lib"/*.dylib; do
  base="$(basename "$lib")"
  install_name_tool -id "@rpath/$base" "$lib"
  otool -L "$lib" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    case "$dep" in
      *libggml*.dylib|*libqwen3tts*.dylib)
        flat="$(strip_version "$(basename "$dep")")"
        [ "$dep" != "@rpath/$flat" ] && install_name_tool -change "$dep" "@rpath/$flat" "$lib"
        ;;
    esac
  done
  codesign -f -s - "$lib" >/dev/null 2>&1 || true
done

echo "== qwen3tts vendor artifacts =="
ls -la "$VENDOR/lib"
echo "== dependency check (should be @rpath/ or system paths only) =="
for lib in "$VENDOR/lib"/*.dylib; do
  [ -L "$lib" ] && continue
  echo "--- $(basename "$lib")"; otool -L "$lib" | tail -n +2
done
