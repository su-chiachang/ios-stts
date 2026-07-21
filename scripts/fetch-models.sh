#!/usr/bin/env bash
# Download the default STT model and a qwentts.cpp Base talker/codec pair.
# Usage: scripts/fetch-models.sh [-m 0.6b|1.7b] [-q bf16|q8_0|q4_k_m]
set -euo pipefail

STTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PARAKEET_MODELS="$STTS_DIR/models/parakeet"
QWEN_MODELS="$STTS_DIR/models/qwentts"
HF="https://huggingface.co"
MODEL_SIZE="0.6b"
QUANTIZATION="q4_k_m"

usage() {
  echo "usage: $0 [-m 0.6b|1.7b] [-q bf16|q8_0|q4_k_m]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -m)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      MODEL_SIZE="$2"
      shift 2
      ;;
    -q)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      QUANTIZATION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

case "$MODEL_SIZE" in
  0.6b|1.7b) ;;
  *) usage; exit 2 ;;
esac

case "$QUANTIZATION" in
  bf16) UPSTREAM_QUANTIZATION="BF16" ;;
  q8_0) UPSTREAM_QUANTIZATION="Q8_0" ;;
  q4_k_m) UPSTREAM_QUANTIZATION="Q4_K_M" ;;
  *) usage; exit 2 ;;
esac

fetch() {
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then echo "exists: $dest"; return 0; fi
  echo "downloading: $dest"
  curl -fL --retry 3 -C - -o "$dest.part" "$url"
  mv "$dest.part" "$dest"
}

mkdir -p "$PARAKEET_MODELS" "$QWEN_MODELS"
fetch "$HF/mudler/parakeet-cpp-gguf/resolve/main/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf" \
      "$PARAKEET_MODELS/nemotron-3.5-asr-streaming-0.6b-q8_0.gguf"
fetch "$HF/mudler/parakeet-cpp-gguf/resolve/main/realtime_eou_120m-v1-q8_0.gguf" \
      "$PARAKEET_MODELS/realtime_eou_120m-v1-q8_0.gguf"

# qwentts.cpp reads the model type from the talker metadata. To use 1.7B,
# CustomVoice, or VoiceDesign, add that talker pair to this directory and
# select it in Settings.
TTS_REPO="Serveurperso/Qwen3-TTS-GGUF"
fetch "$HF/$TTS_REPO/resolve/main/qwen-talker-$MODEL_SIZE-base-$UPSTREAM_QUANTIZATION.gguf" \
      "$QWEN_MODELS/qwen-talker-$MODEL_SIZE-base-$UPSTREAM_QUANTIZATION.gguf"
fetch "$HF/$TTS_REPO/resolve/main/qwen-tokenizer-12hz-$UPSTREAM_QUANTIZATION.gguf" \
      "$QWEN_MODELS/qwen-tokenizer-12hz-$UPSTREAM_QUANTIZATION.gguf"

echo "== models =="
ls -la "$PARAKEET_MODELS" "$QWEN_MODELS"
