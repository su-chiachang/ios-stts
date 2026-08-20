#!/usr/bin/env python3
"""
stt_eval.py — 比較兩套 STT（例如 Apple Native Speech vs Azure Fast）
相對於 YouTube 字幕（ground truth）的辨識正確率。

支援輸入格式：.srt / .vtt / .txt（純文字）
支援語言：zh（中文，計算 CER）/ en（英文，計算 WER）

依賴套件：
    pip install jiwer opencc-python-reimplemented cn2an --break-system-packages

使用範例：
    python stt_eval.py --lang zh \
        --ref subs_zh.srt \
        --hyp apple_zh.srt:Apple \
        --hyp azure_zh.srt:Azure

    python stt_eval.py --lang en \
        --ref subs_en.vtt \
        --hyp apple_en.txt:Apple \
        --hyp azure_en.txt:Azure

也可以同一次跑中英文兩份檔案：
    python stt_eval.py --lang zh --ref ... --hyp a:Apple --hyp b:Azure
    python stt_eval.py --lang en --ref ... --hyp a:Apple --hyp b:Azure
"""

import argparse
import re
import sys
import unicodedata
import warnings
from pathlib import Path

import jiwer

try:
    from opencc import OpenCC
    _opencc = OpenCC('s2twp')  # 簡體轉繁體並轉台灣慣用字/詞；若字幕本身是繁體，簡體字不會被誤轉
except ImportError:
    _opencc = None

try:
    import cn2an
    _has_cn2an = True
except ImportError:
    _has_cn2an = False


# ---------------------------------------------------------------------------
# 1. 讀取字幕 / 純文字檔，抽取純語音文字
# ---------------------------------------------------------------------------

NON_SPEECH_TAG_RE = re.compile(
    r"\[[^\]]*\]|\([^)]*\)|（[^）]*）|【[^】]*】", re.UNICODE
)
# 例如 [Music] [掌聲] (inaudible) （音樂）等非語音標記

SRT_TIMESTAMP_RE = re.compile(
    r"^\d{2}:\d{2}:\d{2}[,.]\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}[,.]\d{3}.*$"
)
VTT_TIMESTAMP_RE = re.compile(
    r"^\d{2}:\d{2}:\d{2}\.\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}\.\d{3}.*$"
)
INDEX_LINE_RE = re.compile(r"^\d+$")
VTT_TAG_RE = re.compile(r"<[^>]+>")  # <c>, <v Speaker> 之類的 VTT 內嵌標籤


def load_text(path: str) -> str:
    """依副檔名解析 srt / vtt / txt，回傳串接後的純文字（一行一句話，用空白分隔）。"""
    p = Path(path)
    raw = p.read_text(encoding="utf-8-sig", errors="ignore")
    ext = p.suffix.lower()

    lines_out = []
    if ext == ".srt":
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            if INDEX_LINE_RE.match(line):
                continue
            if SRT_TIMESTAMP_RE.match(line):
                continue
            lines_out.append(line)
    elif ext == ".vtt":
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            if line.upper().startswith("WEBVTT"):
                continue
            if line.upper().startswith("NOTE"):
                continue
            if line.lower().startswith("kind:") or line.lower().startswith("language:"):
                continue
            if VTT_TIMESTAMP_RE.match(line):
                continue
            if INDEX_LINE_RE.match(line):
                continue
            line = VTT_TAG_RE.sub("", line)
            lines_out.append(line)
    else:
        # 純文字檔：整份當作一段文字
        lines_out = raw.splitlines()

    text = " ".join(lines_out)
    text = NON_SPEECH_TAG_RE.sub(" ", text)
    return text


# ---------------------------------------------------------------------------
# 2. 正規化：中文
# ---------------------------------------------------------------------------

# 全形轉半形（數字、英文字母、常見符號）
def fullwidth_to_halfwidth(text: str) -> str:
    result = []
    for ch in text:
        code = ord(ch)
        if code == 0x3000:  # 全形空白
            code = 0x20
        elif 0xFF01 <= code <= 0xFF5E:  # 全形字元區
            code -= 0xFEE0
        result.append(chr(code))
    return "".join(result)


# 中英文標點符號（含全形），移除標點時使用
CJK_PUNCTUATION = (
    "，。、；：？！「」『』（）〈〉《》【】〔〕‘’“”…—～·"
    ",.;:?!\"'()[]{}<>_-~`@#$%^&*+=|\\/"
)
PUNCT_TABLE = str.maketrans("", "", CJK_PUNCTUATION)


def normalize_zh(text: str, keep_punctuation: bool = False) -> str:
    text = fullwidth_to_halfwidth(text)

    if _opencc is not None:
        text = _opencc.convert(text)

    if _has_cn2an:
        # 將中文數字（一二三…）與阿拉伯數字先統一成阿拉伯數字，
        # 避免 "2026" vs "二〇二六" 被誤判為錯誤。失敗時保留原文字。
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                text = cn2an.transform(text, "cn2an")
        except Exception:
            pass

    # 移除所有空白字元（中文字之間本來就不該有空格）
    text = re.sub(r"\s+", "", text)

    if not keep_punctuation:
        text = text.translate(PUNCT_TABLE)

    # 英文字母部分順手轉小寫，避免中英夾雜時大小寫造成誤判
    text = text.lower()

    return text


def zh_to_char_list(text: str) -> str:
    """把中文字串轉成『每個字元中間加空白』的形式，
    讓 jiwer 的 WER 計算方式等同於逐字元比較（即 CER）。"""
    return " ".join(list(text))


# ---------------------------------------------------------------------------
# 3. 正規化：英文
# ---------------------------------------------------------------------------

CONTRACTIONS = {
    "don't": "do not", "doesn't": "does not", "didn't": "did not",
    "won't": "will not", "can't": "cannot", "isn't": "is not",
    "aren't": "are not", "wasn't": "was not", "weren't": "were not",
    "haven't": "have not", "hasn't": "has not", "hadn't": "had not",
    "shouldn't": "should not", "wouldn't": "would not",
    "couldn't": "could not", "it's": "it is", "that's": "that is",
    "there's": "there is", "here's": "here is", "what's": "what is",
    "let's": "let us", "i'm": "i am", "you're": "you are",
    "we're": "we are", "they're": "they are", "i've": "i have",
    "you've": "you have", "we've": "we have", "they've": "they have",
    "i'll": "i will", "you'll": "you will", "we'll": "we will",
    "they'll": "they will", "i'd": "i would", "you'd": "you would",
}


def normalize_unicode_punct(text: str) -> str:
    replacements = {
        "’": "'", "‘": "'", "“": '"', "”": '"',
        "—": "-", "–": "-", "…": "...",
    }
    for src, dst in replacements.items():
        text = text.replace(src, dst)
    text = unicodedata.normalize("NFKC", text)
    return text


def expand_contractions(text: str) -> str:
    words = text.split()
    return " ".join(CONTRACTIONS.get(w, w) for w in words)


def normalize_en(text: str, keep_punctuation: bool = False,
                 expand_contraction: bool = True) -> str:
    text = normalize_unicode_punct(text)
    text = text.lower()

    if expand_contraction:
        text = expand_contractions(text)

    if not keep_punctuation:
        # 保留字母、數字與空白，其餘標點移除
        text = re.sub(r"[^\w\s]", " ", text, flags=re.UNICODE)

    text = re.sub(r"\s+", " ", text).strip()
    return text


# ---------------------------------------------------------------------------
# 4. 計算與報表
# ---------------------------------------------------------------------------

def compute_metric(lang: str, ref_raw: str, hyp_raw: str, keep_punct: bool):
    if lang == "zh":
        ref_norm = normalize_zh(ref_raw, keep_punctuation=keep_punct)
        hyp_norm = normalize_zh(hyp_raw, keep_punctuation=keep_punct)
        ref_for_jiwer = zh_to_char_list(ref_norm)
        hyp_for_jiwer = zh_to_char_list(hyp_norm)
        score = jiwer.wer(ref_for_jiwer, hyp_for_jiwer)  # 字元級 WER = CER
        out = jiwer.process_words(ref_for_jiwer, hyp_for_jiwer)
    else:
        ref_norm = normalize_en(ref_raw, keep_punctuation=keep_punct)
        hyp_norm = normalize_en(hyp_raw, keep_punctuation=keep_punct)
        score = jiwer.wer(ref_norm, hyp_norm)
        out = jiwer.process_words(ref_norm, hyp_norm)

    return {
        "score": score,
        "substitutions": out.substitutions,
        "deletions": out.deletions,
        "insertions": out.insertions,
        "hits": out.hits,
        "ref_units": out.hits + out.substitutions + out.deletions,
    }


def fmt_pct(x: float) -> str:
    return f"{x * 100:.2f}%"


def main():
    parser = argparse.ArgumentParser(
        description="評比 STT 辨識結果相對於字幕 ground truth 的正確率（中文 CER / 英文 WER）"
    )
    parser.add_argument("--lang", choices=["zh", "en"], required=True,
                         help="語言：zh 中文（算 CER）/ en 英文（算 WER）")
    parser.add_argument("--ref", required=True,
                         help="ground truth 字幕檔路徑（.srt/.vtt/.txt）")
    parser.add_argument("--hyp", action="append", required=True,
                         metavar="PATH:NAME",
                         help="STT 輸出檔路徑與名稱，格式 path:name，"
                              "可重複給多個，例如 --hyp apple.srt:Apple --hyp azure.srt:Azure")
    parser.add_argument("--keep-punctuation", action="store_true",
                         help="同時計算「保留標點符號」版本的結果（額外指標，不影響主指標）")
    args = parser.parse_args()

    ref_raw = load_text(args.ref)
    if not ref_raw.strip():
        sys.exit(f"[錯誤] 讀不到 ground truth 內容：{args.ref}")

    hyps = []
    for item in args.hyp:
        if ":" not in item:
            sys.exit(f"[錯誤] --hyp 格式需為 path:name，收到：{item}")
        path, name = item.rsplit(":", 1)
        hyp_raw = load_text(path)
        hyps.append((name, path, hyp_raw))

    metric_name = "CER" if args.lang == "zh" else "WER"
    print(f"\n=== STT 評測結果（語言：{args.lang} ｜ 指標：{metric_name}，不含標點）===\n")
    print(f"Ground truth: {args.ref}")
    print(f"{'系統':<12}{metric_name+' (%)':<12}{'替代':<8}{'刪除':<8}{'插入':<8}{'參考單位數':<10}")
    print("-" * 62)

    results_no_punct = {}
    for name, path, hyp_raw in hyps:
        r = compute_metric(args.lang, ref_raw, hyp_raw, keep_punct=False)
        results_no_punct[name] = r
        print(f"{name:<12}{fmt_pct(r['score']):<12}{r['substitutions']:<8}"
              f"{r['deletions']:<8}{r['insertions']:<8}{r['ref_units']:<10}")

    if args.keep_punctuation:
        print(f"\n=== 附加指標：{metric_name}（含標點符號）===\n")
        print(f"{'系統':<12}{metric_name+' (%)':<12}")
        print("-" * 24)
        for name, path, hyp_raw in hyps:
            r = compute_metric(args.lang, ref_raw, hyp_raw, keep_punct=True)
            print(f"{name:<12}{fmt_pct(r['score']):<12}")

    print()
    best = min(results_no_punct.items(), key=lambda kv: kv[1]["score"])
    print(f"👉 {metric_name} 較低（較準確）的是：{best[0]}（{fmt_pct(best[1]['score'])}）\n")


if __name__ == "__main__":
    main()

