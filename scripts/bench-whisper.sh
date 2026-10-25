#!/bin/bash
# whisper.cpp のモデル別ベンチを取り、Markdown の表を標準出力に出す（計画 00 Task 5 のスパイク用）。
# 先に scripts/setup-whisper.sh と scripts/make-sample-audio.sh を実行しておく。
#
# 使い方: scripts/bench-whisper.sh [--load]
#   --load      `yes > /dev/null &` を 2 本走らせた状態で測る（終了時に必ず kill する）
#   MODELS      測るモデル（空白区切り。既定: 計画の 7 モデル）。例: MODELS="base" scripts/bench-whisper.sh
#   THREADS     スレッド数（既定: 4）
#   OUT_DIR     whisper-cli の出力テキストの置き場所（既定: /tmp）。out-<モデル>-<ビルド>[-load].txt
#   LOG_DIR     whisper-bench / whisper-cli のログ全文の置き場所（既定: tools/bench-logs）
#   BUILDS      測るビルド（既定: "build build-metal"。無いビルドは省略）。例: BUILDS="build"
#   PYTHON      cer.py を動かす python3（既定: python3）
#
# 表の列:
#   bench encode   whisper-bench の encode time（ms）
#   経過秒         whisper-cli で ja-5min.wav を文字起こしした壁時計の秒数（モデル読み込みを含む）
#   RTF            経過秒 ÷ 音声の実測秒（afinfo）
#   CER            scripts/cer.py の値（NFKC・空白除去後）。CER(記号除く) は --no-punct の値
# 合成音声なので CER は参考値（人の声より楽）。
# build-metal/ があれば、同じ表を Metal ビルドでもう一度出す（BUILDS で外せる）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_DIR="$REPO_ROOT/tools/whisper.cpp"
SAMPLE_WAV="$REPO_ROOT/tools/samples/ja-5min.wav"
SAMPLE_REF="$REPO_ROOT/tools/samples/ja-5min.txt"
MODELS="${MODELS:-base small small-q5_1 medium medium-q5_0 large-v3-turbo large-v3-turbo-q5_0}"
THREADS="${THREADS:-4}"
OUT_DIR="${OUT_DIR:-/tmp}"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/tools/bench-logs}"
BUILDS="${BUILDS:-build build-metal}"
PYTHON="${PYTHON:-python3}"

LOAD=0
for arg in "$@"; do
    case "$arg" in
        --load) LOAD=1 ;;
        *) echo "不明な引数: ${arg}（使えるのは --load だけ）" >&2; exit 2 ;;
    esac
done

[ -f "$SAMPLE_WAV" ] && [ -f "$SAMPLE_REF" ] || { echo "サンプル音声が無い。scripts/make-sample-audio.sh を先に実行する" >&2; exit 1; }
mkdir -p "$OUT_DIR" "$LOG_DIR"

now() { "$PYTHON" -I -c 'import time; print(f"{time.time():.3f}")'; }
audio_sec="$(afinfo "$SAMPLE_WAV" | awk '/estimated duration/ {print $3}' || true)"
# 空や 0 のまま進むと RTF の awk がゼロ除算で止まり、表が途中で切れる。先に止める。
if ! awk -v a="$audio_sec" 'BEGIN { exit !(a + 0 > 0) }'; then
    echo "音声の長さを afinfo から取れない（得た値: '${audio_sec}'）: $SAMPLE_WAV" >&2
    exit 1
fi

# 負荷あり: yes を 2 本。どの終わり方でも必ず止める。
# 計測中の子プロセスもバックグラウンドで起動して wait する。フォアグラウンドで動かすと
# bash は子の終了まで INT/TERM の trap を遅らせるため、Ctrl-C で yes が残り続ける。
LOAD_PIDS=""
CHILD_PID=""
run_child() {  # run_child <ログ> <コマンド...>
    local log="$1"; shift
    "$@" > "$log" 2>&1 &
    CHILD_PID=$!
    local rc=0
    wait "$CHILD_PID" || rc=$?
    CHILD_PID=""
    return "$rc"
}
cleanup() {
    if [ -n "$CHILD_PID" ]; then
        kill "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
        CHILD_PID=""
    fi
    if [ -n "$LOAD_PIDS" ]; then
        # shellcheck disable=SC2086
        kill $LOAD_PIDS 2>/dev/null || true
        wait $LOAD_PIDS 2>/dev/null || true
        LOAD_PIDS=""
    fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM
if [ "$LOAD" = 1 ]; then
    yes > /dev/null &
    LOAD_PIDS="$!"
    yes > /dev/null &
    LOAD_PIDS="$LOAD_PIDS $!"
fi

suffix=""
[ "$LOAD" = 1 ] && suffix="-load"

bench_build() {
    local build="$1"
    local bin="$WHISPER_DIR/$build/bin"
    echo
    echo "### ${build}（-t ${THREADS}、負荷: $([ "$LOAD" = 1 ] && echo 'yes ×2' || echo 'なし')、音声 ${audio_sec} 秒）"
    echo
    echo "| モデル | bench encode (ms) | 経過秒 | RTF | CER | CER(記号除く) |"
    echo "|---|---|---|---|---|---|"
    local m model tag bench_log cli_log out encode start end elapsed rtf cer cer_np
    for m in $MODELS; do
        model="$WHISPER_DIR/models/ggml-$m.bin"
        if [ ! -s "$model" ]; then
            echo "| $m | モデル無し | - | - | - | - |"
            continue
        fi
        tag="$m-$build$suffix"
        bench_log="$LOG_DIR/bench-$tag.log"
        cli_log="$LOG_DIR/cli-$tag.log"
        out="$OUT_DIR/out-$tag"

        # (a) whisper-bench
        if run_child "$bench_log" "$bin/whisper-bench" -m "$model" -t "$THREADS"; then
            encode="$(awk -F'=' '/encode time/ { split($2, a, " "); print a[1]; exit }' "$bench_log")"
            [ -n "$encode" ] || encode="?"
        else
            encode="失敗"
        fi

        # (b) whisper-cli で ja-5min.wav を文字起こしした経過秒
        start="$(now)"
        if run_child "$cli_log" "$bin/whisper-cli" -m "$model" -l ja -t "$THREADS" -f "$SAMPLE_WAV" -otxt -of "$out"; then
            end="$(now)"
            elapsed="$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.1f", e - s }')"
            # (c) RTF
            rtf="$(awk -v e="$elapsed" -v a="$audio_sec" 'BEGIN { printf "%.3f", e / a }')"
            # (d) CER。出力 txt が無い・cer.py が失敗したときは、その行を "-" にして次のモデルへ進む
            #     （set -e で長時間ベンチ全体が止まらないように）
            cer="-"; cer_np="-"
            if [ -f "$out.txt" ]; then
                cer="$("$PYTHON" -I "$REPO_ROOT/scripts/cer.py" "$out.txt" "$SAMPLE_REF" 2>>"$cli_log")" || cer="-"
                cer_np="$("$PYTHON" -I "$REPO_ROOT/scripts/cer.py" --no-punct "$out.txt" "$SAMPLE_REF" 2>>"$cli_log")" || cer_np="-"
                [ -n "$cer" ] || cer="-"
                [ -n "$cer_np" ] || cer_np="-"
            else
                echo "出力テキストが無い: $out.txt" >> "$cli_log"
            fi
        else
            elapsed="失敗"; rtf="-"; cer="-"; cer_np="-"
        fi
        echo "| $m | $encode | $elapsed | $rtf | $cer | $cer_np |"
    done
}

echo "## whisper.cpp ベンチ（$(date '+%Y-%m-%d %H:%M')、$(git -C "$WHISPER_DIR" describe --tags 2>/dev/null || echo 'タグ不明')）"
for b in $BUILDS; do
    if [ -x "$WHISPER_DIR/$b/bin/whisper-cli" ] && [ -x "$WHISPER_DIR/$b/bin/whisper-bench" ]; then
        bench_build "$b"
    else
        echo
        echo "（${b}/ が無いので表は省略）"
    fi
done
echo
echo "ログ全文: ${LOG_DIR}、出力テキスト: $OUT_DIR/out-*.txt。合成音声なので CER は参考値（人の声より楽）。"
