#!/bin/bash
# whisper ベンチ用のサンプル音声を合成する（計画 00 Task 5 のスパイク用）。
#
# 入力（コミット済み。ベンチの CER の参照テキストそのもの）:
#   scripts/samples/ja-5min.txt  日本語 約 5 分ぶんの読み上げ文
#   scripts/samples/en-30s.txt   英語 約 30 秒ぶんの読み上げ文
# 出力（tools/ は .gitignore 済み。コミットしない）:
#   tools/samples/ja-5min.wav  日本語 約 5 分（16kHz モノラル 16bit）
#   tools/samples/en-30s.wav   英語 約 30 秒（16kHz モノラル 16bit。日本語とは別ファイルのまま）
#
# 使い方: scripts/make-sample-audio.sh
#   JA_VOICE    日本語ボイス（既定: Kyoko。無ければ say -v '?' の ja_JP の先頭）
#   EN_VOICE    英語ボイス（既定: Samantha）
#
# 参照テキストは計画 00 Task 5 で要件書の第 1〜4 章から作り、5 分に切り詰めたもの。
# 要件書はその後書き換わったので、作り直さずに固定のテキストを読み上げるだけにする
# （Intel と Apple Silicon で同じ入力を使うため）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/scripts/samples"
OUT="$REPO_ROOT/tools/samples"
EN_VOICE="${EN_VOICE:-Samantha}"
RATE=180

log() { echo "[make-sample-audio] $*"; }

# afinfo の "estimated duration: 301.234 sec" から秒数を取る
duration() { afinfo "$1" | awk '/estimated duration/ {print $3}'; }

# 日本語ボイスの決定
if [ -z "${JA_VOICE:-}" ]; then
    if say -v '?' | grep -q '^Kyoko '; then
        JA_VOICE=Kyoko
    else
        JA_VOICE="$(say -v '?' | grep 'ja_JP' | head -1 | sed -E 's/ +ja_JP.*//; s/ *\(.*\)$//')"
        [ -n "$JA_VOICE" ] || { echo "日本語ボイスが見つからない" >&2; exit 1; }
    fi
fi
log "日本語ボイス: ${JA_VOICE}（-r ${RATE}）、英語ボイス: $EN_VOICE"

mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for f in ja-5min.txt en-30s.txt; do
    [ -f "$SRC/$f" ] || { echo "参照テキストが無い: $SRC/$f" >&2; exit 1; }
done

# 1. 日本語 約 5 分
say -v "$JA_VOICE" -r "$RATE" -o "$TMP/ja.aiff" -f "$SRC/ja-5min.txt"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/ja.aiff" "$OUT/ja-5min.wav"
log "ja-5min.wav: $(duration "$OUT/ja-5min.wav") 秒、参照テキスト $(wc -l < "$SRC/ja-5min.txt" | tr -d ' ') 行"

# 2. 英語 約 30 秒
say -v "$EN_VOICE" -o "$TMP/en.aiff" -f "$SRC/en-30s.txt"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/en.aiff" "$OUT/en-30s.wav"
log "en-30s.wav: $(duration "$OUT/en-30s.wav") 秒"

ls -l "$OUT"
