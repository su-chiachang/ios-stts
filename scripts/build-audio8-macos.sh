#!/usr/bin/env bash
# Build Audio8 as a macOS arm64 static archive with its GGML implementation
# localized so it can coexist with Parakeet's static GGML and Qwen's dylib.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

STTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AUDIO8_SRC="${AUDIO8_SRC:-$STTS_DIR/../audio8.cpp}"
GGML_SRC="${AUDIO8_GGML_SOURCE_DIR:-$STTS_DIR/../audio.cpp/external/ggml}"
TOKENIZER_SRC="${AUDIO8_TOKENIZER_SOURCE_DIR:-$STTS_DIR/../audio.cpp}"
BUILD_DIR="$STTS_DIR/build/audio8-macos"
INSTALL_DIR="$BUILD_DIR/install"
VENDOR="$STTS_DIR/vendor/audio8"
ARCH="arm64"
JOBS="${BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || true)}"
JOBS="${JOBS:-4}"

CMAKE_ARGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_ARCHITECTURES="$ARCH"
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
  -DBUILD_SHARED_LIBS=OFF
  -DAUDIO8_BUILD_TESTS=ON
  -DAUDIO8_BUILD_RUNTIME=ON
  -DAUDIO8_ENABLE_METAL=ON
  -DAUDIO8_ENABLE_INSTALL=ON
  -DAUDIO8_GGML_SOURCE_DIR="$GGML_SRC"
  -DAUDIO8_TOKENIZER_SOURCE_DIR="$TOKENIZER_SRC"
  -DAUDIO8_TEST_GENERATOR_GGUF="${AUDIO8_TEST_GENERATOR_GGUF:-}"
  -DAUDIO8_TEST_CODEC_GGUF="${AUDIO8_TEST_CODEC_GGUF:-}"
  -DAUDIO8_TEST_TOKENIZER_JSON="${AUDIO8_TEST_TOKENIZER_JSON:-}"
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
)

for required in "$AUDIO8_SRC/CMakeLists.txt" "$GGML_SRC/CMakeLists.txt" \
  "$TOKENIZER_SRC/external/cJSON/cJSON.c"; do
  if [ ! -e "$required" ]; then
    echo "error: missing Audio8 build dependency: $required" >&2
    exit 1
  fi
done

cmake -S "$AUDIO8_SRC" -B "$BUILD_DIR" "${CMAKE_ARGS[@]}"

TEST_TARGETS=(
  audio8-core
  audio8-c-consumer-smoke
  audio8-ggml-smoke
  audio8-prompt-smoke
  audio8-metal-smoke
)
if [ -n "${AUDIO8_TEST_TOKENIZER_JSON:-}" ]; then
  TEST_TARGETS+=(audio8-tokenizer-smoke)
fi
if [ -n "${AUDIO8_TEST_GENERATOR_GGUF:-}" ]; then
  TEST_TARGETS+=(audio8-model-inspect audio8-generator-smoke)
fi
if [ -n "${AUDIO8_TEST_CODEC_GGUF:-}" ]; then
  TEST_TARGETS+=(audio8-codec-smoke)
fi
if [ -n "${AUDIO8_TEST_GENERATOR_GGUF:-}" ] \
  && [ -n "${AUDIO8_TEST_CODEC_GGUF:-}" ] \
  && [ -n "${AUDIO8_TEST_TOKENIZER_JSON:-}" ]; then
  TEST_TARGETS+=(audio8-runtime-smoke audio8-pipeline-smoke audio8-metal-parity-smoke)
fi

cmake --build "$BUILD_DIR" --target "${TEST_TARGETS[@]}" \
  -j"$JOBS"
cmake --install "$BUILD_DIR" --prefix "$INSTALL_DIR"

mkdir -p "$VENDOR/lib" "$VENDOR/include" \
  "$STTS_DIR/Packages/NativeShims/Sources/CAudio8/include"
cp -f "$INSTALL_DIR/include/audio8/audio8_runtime.h" \
  "$VENDOR/include/audio8_runtime.h"
cp -f "$VENDOR/include/audio8_runtime.h" \
  "$STTS_DIR/Packages/NativeShims/Sources/CAudio8/include/audio8_runtime.h"

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

LOCALIZED_O="$BUILD_DIR/audio8_macos_localized.o"
ld -r -arch "$ARCH" -platform_version macos 15.0 15.0 \
  -exported_symbols_list "$PUBLIC_SYMS" \
  "${ARCHIVES[@]}" \
  -o "$LOCALIZED_O"
libtool -static -o "$VENDOR/lib/libaudio8.a" "$LOCALIZED_O"

if [ -n "${AUDIO8_TEST_GENERATOR_GGUF:-}" ] \
  && [ -n "${AUDIO8_TEST_CODEC_GGUF:-}" ] \
  && [ -n "${AUDIO8_TEST_TOKENIZER_JSON:-}" ]; then
  "$BUILD_DIR/audio8-c-consumer-smoke" \
    "$AUDIO8_TEST_GENERATOR_GGUF" \
    "$AUDIO8_TEST_CODEC_GGUF" \
    "$AUDIO8_TEST_TOKENIZER_JSON"
elif [ "${AUDIO8_REQUIRE_MODEL_SMOKE:-0}" = "1" ]; then
  echo "error: model-backed Audio8 smoke requires generator, codec, and tokenizer paths" >&2
  exit 1
else
  echo "warning: model-backed Audio8 smoke skipped; set AUDIO8_TEST_GENERATOR_GGUF, AUDIO8_TEST_CODEC_GGUF, and AUDIO8_TEST_TOKENIZER_JSON (or AUDIO8_REQUIRE_MODEL_SMOKE=1)"
  "$BUILD_DIR/audio8-c-consumer-smoke"
fi

ctest --test-dir "$BUILD_DIR" --output-on-failure

echo "== audio8 macOS artifact =="
lipo -info "$VENDOR/lib/libaudio8.a"
