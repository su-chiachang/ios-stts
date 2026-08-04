# Audio8 TTS 模型大小與記憶體估算

最後更新：2026-08-04

這份表把「下載 bundle 大小」與「runtime peak RSS」分開。F32 與 Q8_0
數字來自 pinned Audio8 checkpoint 的實際 artifact；BF16 是官方 source
檔案的大小；Q4_K_M 目前只有離線估算，不能視為已可載入的 Audio8
deployment artifact。

## 結論

| variant | Generator | Codec + tokenizer | bundle/download size | runtime peak memory | 狀態 |
|---|---:|---:|---:|---:|---|
| F32 reference | 2.405 GB / 2.240 GiB | 1.362 GB / 1.269 GiB | **3.766 GB / 3.508 GiB** | **3.992 GB / 3.718 GiB 實測** | native reference |
| BF16 source | 1.202 GB / 1.120 GiB | 1.362 GB / 1.269 GiB | **2.564 GB / 2.388 GiB** | 約 **2.790 GB / 2.598 GiB** proxy | source only；未納入 native contract |
| Q8_0 hybrid | 1.178 GB / 1.097 GiB | 1.362 GB / 1.269 GiB | **2.540 GB / 2.366 GiB** | **2.738 GB / 2.550 GiB 實測** | native selectable |
| Q4_K_M | 約 0.970 GB / 0.903 GiB | 1.362 GB / 1.269 GiB | 約 **2.331 GB / 2.171 GiB** | 約 **2.529 GB / 2.355 GiB** proxy | 未產生；目前拒絕載入 |

GB 使用十進位 `10^9`，GiB 使用二進位 `2^30`。Codec + tokenizer 的
F32/Q8_0 實際組合是 Codec `1,349,626,432` bytes 加 tokenizer
`12,217,872` bytes。

## 數字來源

- F32 Generator：`2,404,653,632` bytes，SHA-256
  `d435f97a3f755a2b494ecefffda50631173db8275b5723f647d750c049039909`。
- Q8_0 hybrid Generator：`1,178,352,288` bytes，SHA-256
  `96fe2ed44114ecb6d8c8a0439a28052f0ec4895c06858dc0bb6b5dd1ca878512`。
- F32 Codec：`1,349,626,432` bytes，SHA-256
  `8bc2374d16a66b0d8cde4c8c0085173faeb3f9bca05347b93a601fb4998393d2`。
- tokenizer：`12,217,872` bytes，SHA-256
  `f24e08099d45a8adf3f52f5f0b03276e433bb9d689bb15fcbcc48ce58744588b`。
- BF16 source：`model.safetensors` `1,202,342,528` bytes、`codec.pth`
  `1,349,857,559` bytes、tokenizer `12,217,872` bytes。

F32 peak RSS `3,992,305,664` bytes 與 Q8_0 peak RSS `2,737,537,024`
bytes 來自 real-checkpoint runtime smoke，不是只把檔案大小相加。

## 估算方法與限制

BF16 的 memory 數字是以 F32 實測 peak 減去 F32 Generator artifact、再
加回 BF16 source Generator 的線性 proxy：

```text
3,992,305,664 - 2,404,653,632 + 1,202,342,528
= 2,789,994,560 bytes ≈ 2.598 GiB
```

Q4_K_M 的 Generator 數字是假設目前 Q8_0 policy 覆蓋的 417,491,968
個 attention/FFN elements 改以 Q4_K 的 144 bytes / 256 elements 儲存，
其餘 183,667,456 個 sensitive elements 保留 F32，再加上近似 GGUF
metadata。Q4_K_M 實際是 mixed policy，故這是規劃用估算，不是 artifact
hash 或 runtime benchmark。Q4 memory proxy 是以 Q8_0 實測 peak 扣除
Generator 檔案大小差額推算；實際 allocator、scratch buffer、kernel
workspace 與 App overhead 可能更高。

因此目前的 release decision 是：

- 以 **F32** 作為品質與相容性 reference。
- 以 **Q8_0 Generator + F32 Codec** 作為第一個可選 native variant。
- **BF16** 只保留為 source/size baseline；目前 native dtype gate 不接受。
- **Q4_K_M** 只保留為 sizing 方向；尚未完成 exporter、validator、parity
  corpus 與 Metal benchmark，不能放入下載 manifest。
- 現行 8 GiB physical-memory gate 對以上已測與估算數字保守，但正式發布
  仍需完整 corpus、sustained peak memory 與真實 Apple GPU 的 Metal p95。
