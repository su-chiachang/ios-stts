# 以 audio8.cpp 擴充 TTS，保留 qwentts.cpp
# Add audio8.cpp TTS backend while retaining qwentts.cpp

## 繁體中文

### 摘要

將 App 的 TTS 原生實作擴充為 Qwen 與 Audio8 雙 backend。保留現有 Qwen native C ABI 與行為，新增 Audio8 原生 C ABI；使用者透過明確持久化設定選擇 backend，再由 `loadModels()` 載入對應 runtime。同步更新 Swift、模型設定、建置腳本與設定介面。

模型繼續使用現有自動下載框架：Qwen 維持既有雙檔模型，Audio8 新增三項資源 generator GGUF、codec GGUF、`tokenizer.json`。Audio8 實際下載網址作為獨立設定接入，不直接沿用 Qwen URL。

### 主要改動

- NativeShims
  - 新增 `CAudio8` 模組及 `audio8_runtime.h` 公開標頭檔。
  - 從 `/Users/suchiachang/_proj/audio8.cpp` 建置並連結 `audio8-core`。
  - 設定 macOS/iOS arm64 的 GGML、Metal、CPU fallback 與靜態函式庫產物。
  - 保留 `CQwenTTS`、`qwen.h`、`qt_*` 連結及 qwentts 建置腳本引用。
  - 以獨立 `CAudio8` / Audio8 symbols 加入 native runtime，避免與 Qwen symbols 衝突。

- Swift TTS
  - 建立共用 `TtsEngine` seam；保留 `QwenTts`，新增 `Audio8Tts` runtime wrapper。
  - Audio8 初始化時傳入 generator、codec、tokenizer 三個檔案路徑。
  - 使用 `audio8_runtime_synthesize`，複製回傳 PCM 後呼叫 `audio8_audio_buffer_free`。
  - Qwen 選擇時保留既有 speaker、CustomVoice、VoiceDesign、quantization 行為；Audio8 僅提供文字與 reference conditioning。
  - 播放鏈使用穩定的 44.1 kHz queue，必要時轉換 Qwen 24 kHz 輸出。

- 模型與 UI
  - 保留 `ModelCatalog` 的 Qwen 雙檔模型，新增 Audio8 generator/codec/tokenizer 三檔 atomic resource group。
  - 保留 `ModelDownloadManager` 的下載、驗證與目錄管理流程，分別呈現 Qwen/Audio8 readiness。
  - Audio8 下載 URL 作為獨立設定；未設定時明確顯示 unavailable，不回退到 Qwen。
  - 設定頁提供持久化 Qwen/Audio8 backend picker；下載頁與錯誤提示標示所屬 backend。
  - 保留既有 Qwen 參考音訊流程；Audio8 另傳遞 mono float PCM、source sample rate 與 reference transcript。

- 建置與文件
  - 新增 Audio8 macOS/iOS 建置腳本，支援 Metal 與 CPU fallback。
  - 更新 `project.yml`、NativeShims package 與連結參數。
  - 保留 qwentts 建置、vendor 檢查及 dylib embed 邏輯，並與 Audio8 static artifacts 並存。
  - 保留現有未提交的 `docs/` 變更，不覆蓋。

### 測試與驗收

- Audio8 原生函式庫：
  - macOS 靜態函式庫建置成功。
  - iOS arm64 靜態函式庫建置成功。
  - C ABI smoke test 覆蓋初始化、合成、輸出釋放與錯誤釋放。
  - 沒有 Metal 時驗證 CPU fallback。

- App：
  - Swift 編譯通過，且 Qwen/Audio8 都能由 `loadModels()` 建立。
  - Audio8 模型目錄包含三項資源時可初始化；缺少任一資源時顯示明確錯誤。
  - Qwen 與 Audio8 的無參考、參考音訊/轉錄流程均能交給既有播放鏈。
  - 反覆 Qwen → Audio8 → Qwen reload 後，舊 runtime、audio queue 與 reference state 不殘留。
  - 輸出為可播放的單聲道 44.1 kHz queue，資源釋放無洩漏。
  - 搜尋確認 Qwen 與 Audio8 backend 名稱、C ABI 與 linker wiring 都被正確保留。

### 假設

- 「qwerntts.cpp」指目前專案實際使用的 `qwentts.cpp`。
- 不修改 Audio8 參考倉庫，只從其公開安裝產物與 C ABI 接入。
- Qwen 維持正式支援 backend；Audio8 不假裝支援 Qwen 專屬 speaker/instruction controls。
- Audio8 模型下載地址需要作為設定提供；地址缺失時下載功能應安全失敗並提示設定問題。

---

## English

### Summary

Extend the app's native TTS implementation to support both Qwen and Audio8. Retain the existing Qwen C ABI and behavior, add Audio8's public C ABI, and let an explicit persisted setting select which runtime `loadModels()` creates. Update Swift, model configuration, build scripts, and settings UI accordingly.

The existing automatic-download framework remains in place: Qwen keeps its two-file model assets, while Audio8 adds three resources—the generator GGUF, codec GGUF, and `tokenizer.json`. Audio8 download URLs are provided as separate configuration rather than reusing Qwen URLs.

### Key Changes

- NativeShims
  - Add a `CAudio8` module and expose the public `audio8_runtime.h` header.
  - Build and link `audio8-core` from `/Users/suchiachang/_proj/audio8.cpp`.
  - Configure GGML, Metal, CPU fallback, and static-library artifacts for macOS and iOS arm64.
  - Retain `CQwenTTS`, `qwen.h`, `qt_*` link settings, and qwentts build-script references.
  - Add the independent `CAudio8` module and Audio8 symbols without cross-runtime symbol collisions.

- Swift TTS
  - Introduce a shared `TtsEngine` seam; retain `QwenTts` and add an `Audio8Tts` runtime wrapper.
  - Initialize Audio8 with generator, codec, and tokenizer file paths.
  - Call `audio8_runtime_synthesize`, copy the returned PCM, then call `audio8_audio_buffer_free`.
  - Preserve Qwen speaker, CustomVoice, VoiceDesign, and quantization behavior when Qwen is selected; Audio8 exposes text and reference conditioning only.
  - Use a stable 44.1 kHz playback queue and resample Qwen's 24 kHz output when needed.

- Models and UI
  - Retain the two-file Qwen entries in `ModelCatalog` and add an atomic Audio8 generator/codec/tokenizer group.
  - Keep the existing `ModelDownloadManager` download, validation, and directory-management flow with distinct Qwen/Audio8 readiness.
  - Use separate Audio8 resource URLs; when they are not configured, report Audio8 as unavailable instead of falling back to Qwen.
  - Add a persisted Qwen/Audio8 backend picker to Settings and identify the backend on download and error screens.
  - Preserve Qwen reference-audio handling; Audio8 separately forwards mono float PCM, source sample rate, and reference transcript.

- Build and documentation
  - Add Audio8 macOS/iOS build scripts with Metal and CPU-fallback support.
  - Update `project.yml`, the NativeShims package, and linker settings.
  - Retain qwentts builds, vendor checks, and dylib embedding alongside the Audio8 static artifacts.
  - Preserve existing uncommitted changes under `docs/`.

### Tests and Acceptance Criteria

- Native Audio8 library:
  - macOS static library builds successfully.
  - iOS arm64 static library builds successfully.
  - C ABI smoke tests cover initialization, synthesis, output cleanup, and error cleanup.
  - CPU fallback is verified when Metal is unavailable.

- App:
  - Swift compilation succeeds and `loadModels()` can create either Qwen or Audio8.
  - Audio8 initializes when all three resources are present and reports a clear error for any missing resource.
  - Qwen and Audio8 no-reference and reference-audio/transcript flows use the existing playback path.
  - Repeated Qwen → Audio8 → Qwen reloads leave no stale runtime, audio queue, or reference state.
  - Output uses a playable mono 44.1 kHz queue with no native resource leak.
  - Repository search confirms both backend names, C ABIs, and linker wiring are intentionally represented.

### Assumptions

- “qwerntts.cpp” refers to the `qwentts.cpp` implementation currently used by the project.
- The Audio8 reference repository is not modified; integration consumes its public install artifacts and C ABI.
- Qwen remains a supported production backend; Audio8 does not pretend to support Qwen-only speaker or instruction controls.
- Audio8 model download URLs must be supplied as configuration; if URLs are missing, downloading fails safely with a configuration error.
