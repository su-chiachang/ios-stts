#!/usr/bin/env bash
# Download the default STT model and qwentts.cpp's compact Base 0.6B pair.
set -euo pipefail

STTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PARAKEET_MODELS="$STTS_DIR/models/parakeet"
QWEN_MODELS="$STTS_DIR/models/qwentts"
HF="https://huggingface.co"

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
fetch "$HF/$TTS_REPO/resolve/main/qwen-talker-0.6b-base-Q8_0.gguf" \
      "$QWEN_MODELS/qwen-talker-0.6b-base-Q8_0.gguf"
fetch "$HF/$TTS_REPO/resolve/main/qwen-tokenizer-12hz-Q8_0.gguf" \
      "$QWEN_MODELS/qwen-tokenizer-12hz-Q8_0.gguf"

echo "== models =="
ls -la "$PARAKEET_MODELS" "$QWEN_MODELS"
