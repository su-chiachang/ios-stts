#!/usr/bin/env bash
# Download models for stts into stts/models/.
#
# Default: prebuilt GGUFs from HuggingFace (fast path, no Python needed).
#   - STT: mudler/parakeet-cpp-gguf (nemotron streaming + eou_120m)
#   - TTS: badlogicgames/qwen3-tts-0.6b-q8_0-gguf
#     (Q8 talker and F16 tokenizer with the exact filenames qwen3_tts.cpp's
#     loader prefers)
#
# The app also supports two other talker/tokenizer quantization pairs,
# selectable in Settings, if these files are placed in $QWEN_MODELS by hand
# (no verified HF source for them is wired up here yet):
#   - F16:  qwen3-tts-0.6b-f16.gguf          + qwen3-tts-tokenizer-f16.gguf
#   - Q4:   qwen3-tts-0.6b-q4-k-m.gguf       + qwen3-tts-tokenizer-0.6b-q4-k-m.gguf
#
# --convert: instead run the canonical qwen3-tts.cpp conversion pipeline
#   (downloads safetensors + torch, also exports the CoreML code predictor,
#   which the fast path does not provide). Pass --type q4_k to
#   convert_tts_to_gguf.py for the Q4 talker.
set -euo pipefail

STTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QWEN_SRC="$(cd "$STTS_DIR/qwen3-tts.cpp" && pwd)"
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
  # This repository publishes artifacts directly compatible with
  # qwen3-tts.cpp's Q8-preferred filenames.
  TTS_REPO="badlogicgames/qwen3-tts-0.6b-q8_0-gguf"
  # qwen3_tts.cpp prefers this Q8 model automatically when it is present;
  # it is substantially smaller than the F16 talker while retaining quality.
  fetch "$HF/$TTS_REPO/resolve/main/qwen3-tts-0.6b-q8_0.gguf" \
        "$QWEN_MODELS/qwen3-tts-0.6b-q8_0.gguf"
  fetch "$HF/$TTS_REPO/resolve/main/qwen3-tts-tokenizer-f16.gguf" \
        "$QWEN_MODELS/qwen3-tts-tokenizer-f16.gguf"
fi

echo "== models =="
ls -la "$PARAKEET_MODELS" "$QWEN_MODELS"
