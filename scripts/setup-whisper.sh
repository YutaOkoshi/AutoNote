#!/bin/bash
# whisper.cpp を tools/whisper.cpp に clone してビルドし、ベンチ用のモデルを取得する（計画 00 Task 5 のスパイク用）。
#
# 使い方: scripts/setup-whisper.sh
#   WHISPER_TAG   clone するタグ（既定: v1.9.5。2026-10-24 時点の最新リリース）
#   JOBS          ビルドの並列数（既定: 4）
#   MODELS        取得するモデル（空白区切り。既定: 計画の 7 モデル）
#
# 何度実行してもよい。clone 済み・ビルド済み・取得済みのものはスキップする。
# Metal ビルド（build-metal/）は Intel では best-effort で、失敗しても警告だけ出して続ける。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHISPER_TAG="${WHISPER_TAG:-v1.9.5}"
JOBS="${JOBS:-4}"
MODELS="${MODELS:-base small small-q5_1 medium medium-q5_0 large-v3-turbo large-v3-turbo-q5_0}"
WHISPER_DIR="$REPO_ROOT/tools/whisper.cpp"

log() { echo "[setup-whisper] $*"; }
warn() { echo "[setup-whisper] 警告: $*" >&2; }

mkdir -p "$REPO_ROOT/tools"

# 1. clone
if [ -d "$WHISPER_DIR/.git" ]; then
    current="$(git -C "$WHISPER_DIR" describe --tags --exact-match 2>/dev/null || echo unknown)"
    log "clone 済み（${current}）。スキップ"
    if [ "$current" != "$WHISPER_TAG" ]; then
        warn "既存の clone のタグ (${current}) が WHISPER_TAG (${WHISPER_TAG}) と違う。入れ替えるなら tools/whisper.cpp を消して再実行する"
    fi
else
    log "clone: $WHISPER_TAG"
    git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$WHISPER_DIR"
fi

cd "$WHISPER_DIR"

# 2. CPU ビルド（Accelerate のみ）
#    ggml は APPLE なら Intel でも GGML_METAL を既定で ON にするので、明示的に OFF にして
#    build-metal/ と比べられるようにする。
if [ -x build/bin/whisper-cli ] && [ -x build/bin/whisper-bench ]; then
    log "build/ はビルド済み。スキップ"
else
    log "build/ をビルド（-j${JOBS}）"
    start=$(date +%s)
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=OFF
    cmake --build build -j "$JOBS" --config Release
    log "build/ のビルド時間: $(( $(date +%s) - start )) 秒"
fi

# 3. Metal ビルド（best-effort）
if [ -x build-metal/bin/whisper-cli ] && [ -x build-metal/bin/whisper-bench ]; then
    log "build-metal/ はビルド済み。スキップ"
else
    log "build-metal/ をビルド（-DGGML_METAL=ON、-j${JOBS}、失敗しても続ける）"
    start=$(date +%s)
    if cmake -B build-metal -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=ON \
        && cmake --build build-metal -j "$JOBS" --config Release; then
        log "build-metal/ のビルド時間: $(( $(date +%s) - start )) 秒"
    else
        warn "Metal ビルドに失敗した（$(( $(date +%s) - start )) 秒）。build/ だけで続ける"
    fi
fi

# 4. モデル取得
for m in $MODELS; do
    if [ -s "models/ggml-$m.bin" ]; then
        log "モデル $m は取得済み。スキップ"
        continue
    fi
    log "モデル $m を取得"
    start=$(date +%s)
    bash models/download-ggml-model.sh "$m"
    log "モデル $m の取得時間: $(( $(date +%s) - start )) 秒"
done

log "完了: タグ $WHISPER_TAG"
ls -l models/ggml-*.bin
