# Audio8 TTS Replacement Specification
# Audio8 TTS 替換規格

## Problem Statement

### 繁體中文

目前 App 的 TTS pipeline 依賴 `qwentts.cpp` 與 Qwen 專用的 `qt_*` C ABI。這使 native build、NativeShims、模型下載、設定介面與 Swift TTS wrapper 都綁定在 Qwen 的兩檔模型、取樣率、speaker 模式與參數模型上。Audio8 已提供另一套公開 C ABI、獨立的 generator/codec 模型資源、tokenizer 資源，以及 Metal/CPU fallback runtime，但尚未接入 App。

需要在保留 Qwen 正式支援的前提下，新增 Audio8 boundary，讓 App 透過明確 backend 設定在兩套 native runtime 間切換，同時保留既有對話朗讀、文字轉語音、參考音訊與參考轉錄工作流程。整合不得修改 Audio8 reference repository，且兩套 runtime 必須能安全共存而不發生 symbol 或 lifecycle 衝突。

### English

The app's current TTS pipeline depends on `qwentts.cpp` and its Qwen-specific `qt_*` C ABI. Native builds, NativeShims, model downloads, settings, and the Swift TTS wrapper are therefore coupled to Qwen's two-file model layout, sample rate, speaker modes, and parameter model. Audio8 provides a different public C ABI, separate generator/codec model resources, a tokenizer resource, and Metal/CPU-fallback runtime support, but it is not yet integrated into the app.

The app needs to add an Audio8 boundary while retaining Qwen as a supported backend, allowing an explicit backend setting to switch between the two native runtimes while preserving conversation read-aloud, text-to-speech, reference-audio, and reference-transcript workflows. The Audio8 reference repository must not be modified, and the two runtimes must coexist without symbol or lifecycle conflicts.

## Solution

### 繁體中文

以 Audio8 的公開 C ABI 建立獨立 Audio8 TTS runtime boundary，同時保留既有 Qwen boundary。NativeShims 提供 `CAudio8` module，建置並連結 Audio8 static library；Swift 以共用 TTS seam 管理 backend lifecycle、request mapping、PCM ownership 與錯誤轉換；模型層保留 Qwen 雙檔 asset 並新增三資源 Audio8 asset group；UI 透過明確設定選擇 backend，並依 backend 顯示可用能力。

現有下載框架繼續使用，但每個 Audio8 asset 必須同時描述 generator GGUF、codec GGUF 與 `tokenizer.json`。實際下載 URL 由 Audio8 resource configuration 提供；未配置 URL 或缺少資源時，App 應顯示可理解的 unavailable/configuration error，不回退至 Qwen。

### English

Create an independent Audio8 TTS runtime boundary around Audio8's public C ABI while retaining the existing Qwen boundary. NativeShims will provide a `CAudio8` module and link the Audio8 static library; a shared Swift TTS seam will manage backend lifecycle, request mapping, PCM ownership, and error conversion; the model layer will retain Qwen's two-file assets and add a three-resource Audio8 group; and the UI will select the backend explicitly and show backend-specific capabilities.

The existing download framework remains, but each Audio8 asset must describe the generator GGUF, codec GGUF, and `tokenizer.json` together. Actual download URLs come from Audio8 resource configuration. Missing URLs or resources must produce a clear unavailable/configuration error rather than falling back to Qwen.

## User Stories

### 繁體中文

1. 作為 App 使用者，我想輸入文字並產生語音，以便聆聽文字內容。
2. 作為對話使用者，我想讓 assistant 回覆自動朗讀，以便維持現有語音對話流程。
3. 作為使用者，我想在模型資源完整時啟動 TTS，以便不必理解 native runtime 的內部細節。
4. 作為使用者，我想在缺少 generator、codec 或 tokenizer 任一資源時看到明確錯誤，以便知道如何修復模型設定。
5. 作為使用者，我想從設定頁選擇或重新載入 Audio8 模型資源，以便更換本機模型目錄。
6. 作為使用者，我想透過既有模型下載流程取得 Audio8 的全部資源，以便不必手動逐一管理檔案。
7. 作為使用者，我想在下載 URL 尚未設定時看到設定問題，而不是看到 Qwen 模型錯誤，以便正確判斷問題來源。
8. 作為使用者，我想使用參考音訊合成語音，以便使用自己的聲音特徵。
9. 作為使用者，我想提供參考音訊的文字內容，以便 Audio8 使用 reference conditioning。
10. 作為使用者，我想匯入不同取樣率的參考音訊，以便 App 自動轉換至 Audio8 所需格式。
11. 作為使用者，我想看到 Audio8 產生的音訊正常播放，以便不必手動處理 44.1 kHz 單聲道輸出。
12. 作為使用者，我想在 Metal 不可用時仍能合成，以便 App 可使用 CPU fallback 完成工作。
13. 作為使用者，我想在模型初始化失敗時看到 native error 的可讀訊息，以便知道是資源、格式或 runtime 問題。
14. 作為使用者，我想在選擇 Qwen 時保留其 speaker、CustomVoice、VoiceDesign 與 quantization 能力，選擇 Audio8 時只看到適用的 controls，以便避免選擇無效模式。
15. 作為 App 開發者，我想透過穩定的 Audio8 C ABI 使用 runtime，以便 Swift 不依賴 C++ implementation details。
16. 作為 App 開發者，我想讓 runtime 明確擁有並釋放 native model state，以便避免重複初始化與記憶體洩漏。
17. 作為 App 開發者，我想在複製 PCM output 後釋放 native audio buffer，以便 Swift 音訊生命週期清楚且安全。
18. 作為 App 開發者，我想讓每個 runtime instance 的 synthesis 與 diagnostics 存取序列化，以便符合 Audio8 mutable execution state 契約。
19. 作為 App 開發者，我想讓 macOS 與 iOS arm64 使用同一套 Audio8 boundary，以便降低平台分歧。
20. 作為 App 開發者，我想在不修改 Audio8 reference repository 的情況下整合它，以便 reference implementation 可獨立演進。
21. 作為 App 開發者，我想保留 Qwen 並安全加入 Audio8 的 build、link、vendor check 與 lifecycle 路徑，以便 App 可明確切換而不會意外同時執行兩套 runtime。
22. 作為維護者，我想用 C ABI smoke test 驗證初始化、合成、output cleanup 與 error cleanup，以便 native regression 能在 App build 前被發現。
23. 作為維護者，我想用 App build 驗證 Swift wrapper、model catalog、NativeShims 與 linker wiring，以便確認跨層整合沒有斷裂。
24. 作為維護者，我想讓搜尋結果明確包含 Qwen 與 Audio8 backend contracts、C ABI 與 linker wiring，以便雙 backend 完成狀態可被客觀驗證。

### English

1. As an app user, I want to enter text and generate speech, so that I can listen to written content.
2. As a conversation user, I want assistant replies to be read aloud automatically, so that the existing voice-conversation flow remains useful.
3. As a user, I want TTS to initialize when all model resources are present, so that I do not need to understand native runtime internals.
4. As a user, I want a clear error when the generator, codec, or tokenizer resource is missing, so that I know how to repair model configuration.
5. As a user, I want to select or reload Audio8 model resources from settings, so that I can change the local model directory.
6. As a user, I want the existing model-download flow to obtain all Audio8 resources, so that I do not have to manage each file manually.
7. As a user, I want an explicit configuration error when download URLs are missing, rather than a misleading Qwen model error, so that I can identify the real problem.
8. As a user, I want to synthesize speech from reference audio, so that I can use my own voice characteristics.
9. As a user, I want to provide the reference transcript, so that Audio8 can use reference conditioning.
10. As a user, I want reference audio at different sample rates to be accepted, so that the app converts it to the format required by Audio8.
11. As a user, I want Audio8 output to play normally, so that I do not need to handle 44.1 kHz mono output manually.
12. As a user, I want synthesis to continue when Metal is unavailable, so that CPU fallback keeps the app usable.
13. As a user, I want readable native errors when model initialization fails, so that I can distinguish resource, format, and runtime problems.
14. As a user, I want Qwen's speaker, CustomVoice, VoiceDesign, and quantization capabilities retained when Qwen is selected, while Audio8 shows only applicable controls, so that I cannot select unsupported modes.
15. As an app developer, I want to consume the runtime through a stable Audio8 C ABI, so that Swift does not depend on C++ implementation details.
16. As an app developer, I want each runtime instance to own and release native model state explicitly, so that repeated initialization does not leak memory.
17. As an app developer, I want native audio buffers released after PCM is copied, so that Swift audio ownership is clear and safe.
18. As an app developer, I want synthesis and diagnostics access serialized per runtime instance, so that the Audio8 mutable-execution-state contract is respected.
19. As an app developer, I want macOS and iOS arm64 to use the same Audio8 boundary, so that platform divergence is minimized.
20. As an app developer, I want Audio8 integrated without modifying its reference repository, so that the reference implementation can evolve independently.
21. As an app developer, I want Qwen build/link/vendor/embed paths retained while Audio8 build/link/lifecycle paths are isolated, so that the app can switch explicitly without accidentally running conflicting runtimes.
22. As a maintainer, I want C ABI smoke tests for initialization, synthesis, output cleanup, and error cleanup, so that native regressions are found before the app build.
23. As a maintainer, I want the app build to validate Swift wrapper, model catalog, NativeShims, and linker wiring, so that cross-layer integration is verified.
24. As a maintainer, I want searches to show both Qwen and Audio8 backend contracts, C ABIs, and linker wiring, so that dual-backend completion is objectively verifiable.

## Implementation Decisions

### 繁體中文

- Audio8 公開 C ABI 是 Audio8 的 native TTS boundary；既有 Qwen `qt_*` boundary 保留，不建立跨 backend 的相容 adapter。
- NativeShims 新增 `CAudio8` module，公開 Audio8 runtime header，並從 Audio8 reference checkout 的公開安裝目標建置 static library；`CQwenTTS` 仍維持。
- Audio8 runtime 初始化需要三個不可互換的 resource：generator GGUF、codec GGUF、`tokenizer.json`。Model catalog 將 Audio8 資產視為一個 atomic resource group，Qwen 資產維持既有雙檔契約。
- 保留目前 model download manager 的下載、進度、驗證與狀態管理能力，並分別呈現 Qwen 與 Audio8 的 asset/readiness rules。
- 未配置或無法取得 Audio8 URLs 時，資產狀態為 unavailable/configuration error；不得 fallback 到 Qwen。
- Swift TTS actor 維持 runtime 的單一 owner，負責 create/destroy、synthesis serialization、C string lifetime、PCM copy、native buffer free 與 error translation。
- 共用 TTS seam 支援文字、語言、可選 reference audio、可選 reference transcript 與 max token；Qwen 保留 speaker、CustomVoice、VoiceDesign、quantization semantics，Audio8 只送出其支援的文字/reference conditioning fields。
- Reference audio 在送進 Audio8 前轉為 mono float PCM，保留原始 sample rate metadata，讓 Audio8 runtime 執行必要的 44.1 kHz resampling。
- Audio output contract 為 owned mono float PCM、44.1 kHz；Swift wrapper 在 native buffer cleanup 前完成資料複製。
- App 的 playback layer 不承擔 Qwen 24 kHz 的單一假設；以穩定 44.1 kHz queue 播放，必要時將 Qwen output 轉換後再 enqueue。
- macOS 與 iOS arm64 共用 Audio8 C boundary；Metal 為 preferred backend，CPU fallback 由 Audio8 runtime 負責。
- 保留 Qwen package target、linker flags、build scripts、vendor checks、dylib embedding、model settings 與 UI controls；新增 Audio8 對應 wiring，並由 persisted backend selection 控制 `loadModels()`。
- Audio8 reference repository、其 GGML source 與模型檔不納入本 App repository 的 source mutation；App 只消費公開 headers、static artifacts 與獨立 model resources。
- 主要測試 seam 是 Audio8 Swift wrapper 對 C ABI 的 boundary；原生 smoke test 作為 boundary 的 lower-level gate，整體 App build 作為 wiring gate。

### English

- Audio8's public C ABI is the Audio8 native TTS boundary; retain the existing Qwen `qt_*` boundary and do not build a cross-backend compatibility adapter.
- Add a `CAudio8` NativeShims module, expose the Audio8 runtime header, and build the static library from the public install target of the Audio8 reference checkout; retain `CQwenTTS`.
- Audio8 initialization requires three inseparable resources: the generator GGUF, codec GGUF, and `tokenizer.json`. The model catalog treats the Audio8 group atomically while preserving Qwen's two-file contract.
- Keep the existing model-download manager's download, progress, validation, and state-management behavior with distinct Qwen and Audio8 asset/readiness rules.
- If Audio8 URLs are missing or resources cannot be obtained, report an unavailable/configuration error; never fall back to Qwen.
- Keep one Swift TTS actor as the runtime owner. It handles creation/destruction, synthesis serialization, C-string lifetime, PCM copying, native-buffer cleanup, and error translation.
- The shared TTS seam supports text, language, optional reference audio, optional reference transcript, and max tokens. Qwen speaker, CustomVoice, VoiceDesign, and quantization semantics remain supported for Qwen; Audio8 receives only fields in its own contract.
- Convert reference audio to mono float PCM before passing it to Audio8 while preserving the source sample-rate metadata so the Audio8 runtime can perform required 44.1 kHz resampling.
- The audio output contract is owned mono float PCM at 44.1 kHz; the Swift wrapper copies all data before freeing the native buffer.
- The playback layer must not retain a Qwen-only 24 kHz assumption; it uses a stable 44.1 kHz queue and converts Qwen output before enqueueing when needed.
- macOS and iOS arm64 share the Audio8 C boundary; Metal is preferred and CPU fallback is owned by the Audio8 runtime.
- Retain the Qwen package target, linker flags, build scripts, vendor checks, dylib embedding, model settings, and UI controls; add Audio8 wiring and let persisted backend selection control `loadModels()`.
- Do not mutate the Audio8 reference repository, its GGML sources, or model files from this app repository; consume only public headers, static artifacts, and separately delivered model resources.
- The primary test seam is the Audio8 Swift-wrapper/C-ABI boundary; native smoke tests are the lower-level gate, and the full app build is the wiring gate.

## Testing Decisions

### 繁體中文

- 測試只驗證外部行為與 boundary contract，不鎖定 Audio8 graph 內部實作、GGML tensor layout 或 C++ helper 名稱。
- Native C ABI smoke test 驗證：三項資源成功初始化、缺少/無效資源的錯誤、合成成功、輸出 sample count/rate/channels、buffer free、error free，以及 CPU fallback diagnostics。
- Swift wrapper seam 驗證：runtime lifecycle、request mapping、reference audio conversion、PCM ownership、native error translation、序列化合成與空輸出處理。
- Model layer 驗證：三項資源被視為 atomic group、完整/不完整資產的 readiness state、下載 URL 未設定時的 configuration error，以及下載完成後的重新載入。
- UI/integration 驗證：模型可用時可朗讀，模型不可用時顯示清楚錯誤，參考音訊與轉錄欄位正確傳遞，並依選定 backend 顯示 controls。
- App build gate 驗證：macOS build、iOS arm64 build、NativeShims module import、雙 backend linker wiring 與 Qwen references 的 intentional preservation。
- 音訊驗收驗證：合成輸出為單聲道 44.1 kHz，AudioPlayer 可正確 enqueue/play，native buffer cleanup 後資料仍可播放。
- 測試優先使用現有 native smoke/build seam；目前 repository 沒有成形的 Swift test suite，因此不為純 implementation detail 新增大量低層 mock。

### English

- Tests verify externally observable behavior and boundary contracts, not Audio8 graph internals, GGML tensor layout, or C++ helper names.
- The native C ABI smoke test covers successful initialization with all three resources, missing/invalid-resource errors, successful synthesis, output sample count/rate/channels, buffer cleanup, error cleanup, and CPU-fallback diagnostics.
- The Swift-wrapper seam covers runtime lifecycle, request mapping, reference-audio conversion, PCM ownership, native-error translation, serialized synthesis, and empty-output handling.
- The model layer covers atomic three-resource readiness, complete/incomplete asset states, configuration errors for missing download URLs, and reload after download completion.
- UI/integration behavior covers read-aloud when the selected model is available, clear backend-specific errors when it is unavailable, correct forwarding of reference audio/transcript, and backend-specific controls.
- The app build gate covers macOS build, iOS arm64 build, NativeShims module import, dual-backend linker wiring, and intentional preservation of Qwen production references.
- Audio acceptance covers mono 44.1 kHz output, correct AudioPlayer enqueue/play behavior, and continued playback after native-buffer cleanup.
- Prefer the existing native smoke/build seams; the repository has no established Swift test suite, so do not add broad low-level mocks for implementation details.

## Out of Scope

### 繁體中文

- 不為 Audio8 新增 Qwen speaker/instruction compatibility；Qwen 選擇時既有 speaker、CustomVoice、VoiceDesign 與 quantization 行為保留。
- 不建立 Audio8 streaming synthesis；本規格只涵蓋 buffered output。
- 不新增 Audio8 quantized deployment artifacts；先使用 Audio8 已定義的 F32 model resources。
- 不將大型模型檔提交到 App repository 或直接打包進 App bundle。
- 不修改 Audio8 reference repository 的 model、GGML、C++ graph 或 public ABI。
- 不重新設計整個 AudioPlayer、ConversationEngine 或 STT pipeline；只修改其 TTS integration contract。
- 不處理新的音色管理、模型 marketplace、雲端推論或多模型並行選擇。

### English

- New Qwen compatibility work for Audio8 is out of scope; existing Qwen speaker, CustomVoice, VoiceDesign, and quantization behavior remains supported when Qwen is selected.
- Audio8 streaming synthesis is out of scope; this specification covers buffered output only.
- New Audio8 quantized deployment artifacts are out of scope; use the defined F32 model resources first.
- Large model files are not committed to the app repository or bundled directly in the app.
- The Audio8 reference repository's model, GGML, C++ graph, and public ABI are not modified.
- A broad redesign of AudioPlayer, ConversationEngine, or the STT pipeline is out of scope; only their TTS integration contract changes.
- New voice management, model marketplace, cloud inference, and parallel multi-model selection are out of scope.

## Further Notes

### 繁體中文

- 原始替換計畫保存在 `docs/plans/audio8-replacement-plan.zh-TW-en.md`，本文件是供 issue tracker 與 agent 執行的完整規格。
- Audio8 model download URLs 尚未在 repository 中提供；實作前必須將它們加入 configuration，否則下載功能應維持明確 unavailable 狀態。
- 目前 `gh` GitHub authentication token 無效；若 issue 無法自動建立，請重新執行 `gh auth login -h github.com` 後，以本文件內容建立 issue 並套用 `ready-for-agent` label。

### English

- The source replacement plan is stored at `docs/plans/audio8-replacement-plan.zh-TW-en.md`; this document is the complete execution specification for the issue tracker and implementation agent.
- Audio8 model download URLs are not currently present in the repository; they must be added to configuration before implementation, otherwise download must remain explicitly unavailable.
- The current GitHub `gh` authentication token is invalid. If issue creation cannot complete automatically, rerun `gh auth login -h github.com`, then create an issue from this document and apply the `ready-for-agent` label.
