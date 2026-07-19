#!/usr/bin/env bash
# Download models for stts into stts/models/.
#
# Default: prebuilt GGUFs from HuggingFace (fast path, no Python needed).
#   - STT: mudler/parakeet-cpp-gguf (nemotron streaming + eou_120m)
#   - TTS: badlogicgames/qwen3-tts-0.6b-q8_0-gguf
#     (Q8 talker and F16 tokenizer with the exact filenames qwen3_tts.cpp's
#     loader prefers)
#
# Only this Q8 pair has a verified-compatible HF source: qwen3_tts.cpp's
# vendored loader (see App/TTS/QwenTts.swift and third_party/qwen3-tts.cpp's
# TTSTransformer::create_tensors) hardcodes lookups for tensor names like
# "talker.blk.N...weight" — a convention specific to how this talker was
# converted to GGUF. Other GGUF exports of the same model (e.g.
# hans00/Qwen3-TTS-12Hz-0.6B-GGUF) use a different, more generic tensor
# naming (plain "blk.N...weight") that this loader silently fails to match
# — it ends up with zero tensors and a misleading "Failed to allocate
# tensor buffer" error, not a clear "unrecognized schema" one. Don't wire up
# a new prebuilt source here without first confirming its tensor names carry
# the "talker." prefix (dump the GGUF header, e.g. via `gguf-dump` or a
# quick manual KV/tensor-list parse).
#
# The app also supports two other talker/tokenizer quantization pairs,
# selectable in Settings, if these files are placed in $QWEN_MODELS by hand
# (no verified HF source for them is wired up here yet):
#   - F16:  qwen3-tts-0.6b-f16.gguf          + qwen3-tts-tokenizer-f16.gguf
#.  - Q4:   qwen3-tts-0.6b-q4-k-m.gguf       + qwen3-tts-tokenizer-0.6b-q4-k-m.gguf
#
# --convert: instead run the canonical qwen3-tts.cpp conversion pipeline
#   (downloads safetensors + torch, also exports the CoreML code predictor,
#   which the fast path does not provide). Pass --type q4_k to
#   convert_tts_to_gguf.py for the Q4 talker. This is the only verified way
#   to get F16 or Q4 talkers today.
set -euo pipefail

STTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QWEN_SRC="$(cd "$STTS_DIR/third_party/qwen3-tts.cpp" && pwd)"
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
