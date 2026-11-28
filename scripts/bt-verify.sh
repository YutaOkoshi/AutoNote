#!/usr/bin/env bash
# Bluetooth ヘッドセットを接続した直後の自動録音で「マイクが無音のまま」になる不具合の修正を、実機で無人で確かめる。
# 人の操作は要らない（初回の許可ダイアログだけは例外。出たら止まるので、許可してから再実行する）。
#
# 使い方: scripts/bt-verify.sh --bt-name <名前の一部> [--plan all|baseline|repro|verify|explore|...] [--only ID,...]
#                              [--seconds N] [--out DIR] [--before-app PATH] [--after-app PATH] [--build-before]
#                              [--repeat-before N] [--repeat-after N] [--sound-budget 秒] [--wait-max 分] [--dry-run]
#   --bt-name       ヘッドセットの名前の一部（環境変数 BT_VERIFY_NAME でも可）。アドレスや名前はファイルに書かない
#   --plan          baseline = 計測の基準（アプリなし。タップでトーンが聞こえるか、ヘッドセットのマイクに回り込むか）
#                   repro    = 修正前のビルドで「常駐 → 再生中に接続 → 自動録音」（既定 3 回）
#                   verify   = 修正後のビルドで同じ（既定 5 回）
#                   explore  = 会議アプリの代役（WebRTC のループバック）× 順序 × countdown 0/5/30 × 自動/手動 × 修正前/後
#                   all      = baseline + repro + verify（既定）。カンマで並べてもよい
#   --before-app    修正前のアプリ（既定: この Git リポジトリの他の worktree のうち HEAD が origin/main に含まれる
#                   （未マージの変更が無い）ものの build/AutoNote.app。修正を含まないことも確かめる）。--build-before で origin/main を一時の worktree でビルド
#   --after-app     修正後のアプリ（既定: この worktree の build/AutoNote.app。scripts/build-app.sh release で作る）
#   --dry-run       何も鳴らさず、つながず、起動しない。前提と、いま安全に始められるかだけを表示する。
#                   足りない前提（修正前・修正後のアプリ、blueutil、Chrome）は ✗ の行で出すだけで、終了コードは 0
#                   （ヘッドセットもアプリも無い Mac で通る。scripts/e2e-check.sh の項目 17 が使う）
# 安全条件（各試行の前に確かめる。満たさなければ 5 分待って確かめ直し、--wait-max 分（既定 120）で諦めて終了コード 75）:
#   どの入力デバイスも動作中でない / どの出力デバイスも動作中でない（誰も音を出していない）/ /Applications の AutoNote が録音中でない。
#   /Applications の AutoNote が待機中で動いていれば実験の間だけ終了し、終わったら起動し直す。
# 後片付け（途中で失敗・中断しても）: 一時プロファイルの Chrome、ビルド版アプリ、計測プロセスを終了、ヘッドセットを再接続。
# 音: 一時プロファイルの Chrome（127.0.0.1 のページ。利用者の Chrome とプロファイルには触れない）が 440/660 Hz を小さめに鳴らす。
#   1 回の実行で鳴らすのは --sound-budget 秒（既定 900 = 15 分）まで。システムの音量は変えない。
# 結果: <OUT>/summary.md と <OUT>/results.json（試行ごとの <OUT>/<試行>/result.json・meter.jsonl・rec/）、unified.log。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=""
BEFORE_APP=""
AFTER_APP="${ROOT}/build/AutoNote.app"
BUILD_BEFORE=0
DRY=0
PASS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT="${2:-}"; shift 2 ;;
        --before-app) BEFORE_APP="${2:-}"; shift 2 ;;
        --after-app) AFTER_APP="${2:-}"; shift 2 ;;
        --build-before) BUILD_BEFORE=1; shift ;;
        --dry-run) DRY=1; PASS+=("--dry-run"); shift ;;
        --auto) shift ;;   # 既定（無人で回す）。互換のために受け付ける
        --bt-name|--plan|--only|--seconds|--repeat-before|--repeat-after|--sound-budget|--wait-max|--port)
            [[ $# -ge 2 ]] || { echo "$1 には値が要ります" >&2; exit 2; }
            PASS+=("$1" "$2"); shift 2 ;;
        -h|--help) sed -n 2,26p "$0"; exit 0 ;;
        *) echo "不明なオプション: $1（--help で使い方）" >&2; exit 2 ;;
    esac
done

OUT="${OUT:-${TMPDIR:-/tmp}/bt-verify-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "${OUT}"
command -v swiftc >/dev/null || { echo "swiftc が見つかりません（Command Line Tools が要ります）" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 が見つかりません" >&2; exit 2; }
if ! swiftc -O -suppress-warnings "${ROOT}/scripts/bt-verify-meter.swift" -o "${OUT}/bt-verify-meter" 2>"${OUT}/compile.log"; then
    echo "計測プログラムのコンパイルに失敗しました（${OUT}/compile.log）。SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk を付けて再実行してください" >&2
    exit 2
fi

FIX_MARK="mic rebuild #"
has_fix() { [[ -x "$1/Contents/MacOS/AutoNoteApp" ]] && grep -qaF "${FIX_MARK}" "$1/Contents/MacOS/AutoNoteApp"; }
if [[ -z "${BEFORE_APP}" ]]; then
    main="$(git -C "${ROOT}" rev-parse origin/main 2>/dev/null)"
    while IFS= read -r wt; do
        [[ "${wt}" == "${ROOT}" || -z "${main}" ]] && continue
        git -C "${ROOT}" merge-base --is-ancestor "$(git -C "${wt}" rev-parse HEAD 2>/dev/null)" "${main}" 2>/dev/null || continue
        if [[ -d "${wt}/build/AutoNote.app" ]] && ! has_fix "${wt}/build/AutoNote.app"; then BEFORE_APP="${wt}/build/AutoNote.app"; break; fi
    done < <(git -C "${ROOT}" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
fi
if [[ -z "${BEFORE_APP}" && ${BUILD_BEFORE} == 1 && ${DRY} == 0 ]]; then
    src="${OUT}/before-src"
    echo "修正前（origin/main）を ${src} でビルドします（数分）…"
    git -C "${ROOT}" worktree add -q --detach "${src}" origin/main || exit 2
    mkdir -p "${src}/tools" && cp -R "${ROOT}/tools/whisper.xcframework" "${src}/tools/" || exit 2
    ( cd "${src}" && SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" scripts/build-app.sh release ) >"${OUT}/build-before.log" 2>&1 \
        || { echo "ビルドに失敗しました（${OUT}/build-before.log）" >&2; exit 2; }
    BEFORE_APP="${src}/build/AutoNote.app"
fi

python3 -I "${ROOT}/scripts/bt-verify.py" --root "${ROOT}" --meter "${OUT}/bt-verify-meter" --out "${OUT}" \
    --before-app "${BEFORE_APP:-${OUT}/no-before-app}" --after-app "${AFTER_APP}" "${PASS[@]}"
code=$?
[[ ${DRY} == 1 ]] || echo "結果: ${OUT}/summary.md"
exit ${code}
