#!/usr/bin/env bash
# Download models for stts into stts/models/.
#
# Default: prebuilt GGUFs from HuggingFace (fast path, no Python needed).
#   - STT: mudler/parakeet-cpp-gguf (nemotron streaming + eou_120m)
#   - TTS: Volko76/Qwen3-TTS-12Hz-0.6B-Base-Qwen3tts.cpp_quants-GGUF
#     (community conversion with the exact filenames qwen3_tts.cpp's loader
#     expects; verified against the CLI in M0)
#
# --convert: instead run the canonical qwen3-tts.cpp conversion pipeline
#   (downloads safetensors + torch, also exports the CoreML code predictor,
#   which the fast path does not provide).
set -euo pipefail

STTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QWEN_SRC="$(cd "$STTS_DIR/.." && pwd)"
PARAKEET_MODELS="$STTS_DIR/models/parakeet"
QWEN_MODELS="$STTS_DIR/models/qwen3tts"
HF="https://huggingface.co"

fetch() { # url dest
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then echo "exists: $dest"; return 0; fi
  echo "downloading: $dest"
  curl -fL --retry 3 -C - -o "$dest.part" "$url"
  mv "$dest.part" "$dest"
}

mkdir -p "$PARAKEET_MODELS" "$QWEN_MODELS"

# --- STT (parakeet) ---
fetch "$HF/mudler/parakeet-cpp-gguf/resolve/main/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf" \
      "$PARAKEET_MODELS/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf"
fetch "$HF/mudler/parakeet-cpp-gguf/resolve/main/realtime_eou_120m-v1-q8_0.gguf" \
      "$PARAKEET_MODELS/realtime_eou_120m-v1-q8_0.gguf"

# --- TTS (qwen3-tts) ---
if [ "${1:-}" = "--convert" ]; then
  cd "$QWEN_SRC"
  [ -d .venv ] || uv venv .venv
  # shellcheck disable=SC1091
  source .venv/bin/activate
  uv pip install huggingface_hub gguf torch safetensors numpy tqdm coremltools
  python scripts/setup_pipeline_models.py --models-dir "$QWEN_MODELS"
else
  TTS_REPO="Volko76/Qwen3-TTS-12Hz-0.6B-Base-Qwen3tts.cpp_quants-GGUF"
  fetch "$HF/$TTS_REPO/resolve/main/qwen3-tts-0.6b-f16.gguf" \
        "$QWEN_MODELS/qwen3-tts-0.6b-f16.gguf"
  fetch "$HF/$TTS_REPO/resolve/main/qwen3-tts-tokenizer-f16.gguf" \
        "$QWEN_MODELS/qwen3-tts-tokenizer-f16.gguf"
fi

echo "== models =="
ls -la "$PARAKEET_MODELS" "$QWEN_MODELS"
