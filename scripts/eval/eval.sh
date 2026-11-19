#!/usr/bin/env bash
# 文字起こしの評価の入口: 取得 → 文字起こし → 採点 → 表（基準との差）。取得済み・実行済みのものは飛ばす。
#
#   scripts/eval/eval.sh --autonote <実行ファイル> --label <名前> [--datasets id,id] [--langs ja,auto]
#                        [--set-baseline] [--base <result.json>|none]
#
# 例（修正前を基準にする）:
#   scripts/eval/eval.sh --autonote .build/release/autonote --label main --set-baseline
# 例（修正ブランチを基準と比べる）:
#   scripts/eval/eval.sh --autonote ../fix/.build/release/autonote --label fix
# 詳細は docs/eval/README.md。
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
autonote="" label="" datasets="" langs="" set_baseline="" base=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --autonote) autonote="$2"; shift 2 ;;
        --label) label="$2"; shift 2 ;;
        --datasets) datasets="$2"; shift 2 ;;
        --langs) langs="$2"; shift 2 ;;
        --set-baseline) set_baseline="--set-baseline"; shift ;;
        --base) base="$2"; shift 2 ;;
        *) echo "不明な引数: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$autonote" && -n "$label" ]] || { sed -n '2,10p' "$0" >&2; exit 2; }
[[ -x "$autonote" ]] || { echo "実行ファイルがない: $autonote" >&2; exit 2; }
[[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "--label は英数字と . _ - だけ" >&2; exit 2; }

python3 -I "$here/fetch.py" --datasets "$datasets"
python3 -I "$here/run.py" --autonote "$autonote" --label "$label" --datasets "$datasets" --langs "$langs"
out="$repo/docs/eval/results/$(date +%F)-$label.json"
case ",$datasets," in *,local,*) out="${EVAL_DATA:-$repo/.eval-data}/results/$(date +%F)-$label.json" ;; esac
python3 -I "$here/score.py" --label "$label" --datasets "$datasets" --out "$out" $set_baseline
if [[ -n "$base" ]]; then
    python3 -I "$here/report.py" "$out" --base "$base"
else
    python3 -I "$here/report.py" "$out"
fi
