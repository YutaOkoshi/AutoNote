#!/bin/bash
# whisper ベンチ用のサンプル音声を合成する（計画 00 Task 5 のスパイク用）。
#
# 出力（tools/ は .gitignore 済み。コミットしない）:
#   tools/samples/ja-5min.wav  日本語 約 5 分（16kHz モノラル 16bit）
#   tools/samples/ja-5min.txt  その参照テキスト（CER 計算用。読み上げた文字列そのもの）
#   tools/samples/en-30s.wav   英語 約 30 秒（16kHz モノラル 16bit。日本語とは別ファイルのまま）
#   tools/samples/en-30s.txt   その参照テキスト
#
# 使い方: scripts/make-sample-audio.sh
#   JA_VOICE    日本語ボイス（既定: Kyoko。無ければ say -v '?' の ja_JP の先頭）
#   EN_VOICE    英語ボイス（既定: Samantha）
#   TARGET_SEC  日本語音声の目標秒数（既定: 300）
#
# 日本語テキストは要件書 docs/superpowers/specs/2026-10-24-autonote-design.md の 12〜147 行
# （第 1〜4 章）から Markdown 記号を sed で落として使う。全文を一度合成して長さを測り、
# 目標秒数に収まるよう先頭から行単位で切り詰めて合成し直す。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$REPO_ROOT/docs/superpowers/specs/2026-10-24-autonote-design.md"
OUT="$REPO_ROOT/tools/samples"
TARGET_SEC="${TARGET_SEC:-300}"
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

# 1. 要件書の第 1〜4 章から Markdown 記号を落とす
sed -n '12,147p' "$SPEC" \
    | sed -E \
        -e '/^```/d' \
        -e '/^-{3,}$/d' \
        -e '/^\|[-| :]+\|$/d' \
        -e 's/^#+ +//' \
        -e 's/^ *- +//' \
        -e 's/^ *[0-9]+\. +//' \
        -e 's/^> *//' \
        -e 's/\[([^]]*)\]\([^)]*\)/\1/g' \
        -e 's/\*\*//g' \
        -e 's/`//g' \
        -e 's/^\| *//' \
        -e 's/ *\|$//' \
        -e 's/ *\| */、/g' \
    | awk '{ gsub(/。/, "。\n"); print }' \
    | sed -E '/^[[:space:]]*$/d' > "$TMP/full.txt"   # 切り詰めの単位を細かくするため「。」で改行する

# 2. 全文を合成して長さを測り、目標秒数に合わせて行単位で切り詰める
say -v "$JA_VOICE" -r "$RATE" -o "$TMP/full.aiff" -f "$TMP/full.txt"
full_sec="$(duration "$TMP/full.aiff")"
full_bytes="$(wc -c < "$TMP/full.txt" | tr -d ' ')"
log "全文: ${full_bytes} バイト、${full_sec} 秒"

# 区間によって 1 バイトあたりの秒数が違うので、直前の合成結果の比率で最大 3 回詰め直す。
# 目標の ±3% に入ったら止める。
src_bytes="$full_bytes"; src_sec="$full_sec"
for try in 1 2 3; do
    keep_bytes="$(awk -v b="$src_bytes" -v s="$src_sec" -v t="$TARGET_SEC" 'BEGIN { printf "%d", b * t / s }')"
    awk -v keep="$keep_bytes" '
        { n += length($0) + 1 }   # BSD awk の length はバイト数でも比率なので問題ない
        n > keep && NR > 1 { exit }
        { print }
    ' "$TMP/full.txt" > "$OUT/ja-5min.txt"
    new_bytes="$(wc -c < "$OUT/ja-5min.txt" | tr -d ' ')"
    if [ "$try" -gt 1 ] && [ "$new_bytes" = "$src_bytes" ]; then
        break   # 行単位ではこれ以上詰められない
    fi
    say -v "$JA_VOICE" -r "$RATE" -o "$TMP/ja.aiff" -f "$OUT/ja-5min.txt"
    src_sec="$(duration "$TMP/ja.aiff")"
    src_bytes="$(wc -c < "$OUT/ja-5min.txt" | tr -d ' ')"
    log "試行 ${try}: ${src_bytes} バイト、${src_sec} 秒"
    if awk -v s="$src_sec" -v t="$TARGET_SEC" 'BEGIN { exit !(s > t * 0.97 && s < t * 1.03) }'; then
        break
    fi
done

afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/ja.aiff" "$OUT/ja-5min.wav"
log "ja-5min.wav: $(duration "$OUT/ja-5min.wav") 秒、参照テキスト $(wc -l < "$OUT/ja-5min.txt" | tr -d ' ') 行"

# 3. 英語 約 30 秒
cat > "$OUT/en-30s.txt" <<'EOF'
Good morning everyone, thanks for joining today's weekly sync.
First, the release schedule. We agreed to ship the beta on Friday, and Ken will send the build to the testers on Thursday evening.
Second, the transcription accuracy on Intel Macs is still lower than we hoped, so we will compare the small and medium models next week.
Finally, please add your action items to the shared notes before the end of the day.
Ken, could you also check why the Bluetooth headset keeps disconnecting? Any questions before we wrap up?
EOF
say -v "$EN_VOICE" -o "$TMP/en.aiff" -f "$OUT/en-30s.txt"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/en.aiff" "$OUT/en-30s.wav"
log "en-30s.wav: $(duration "$OUT/en-30s.wav") 秒"

ls -l "$OUT"
