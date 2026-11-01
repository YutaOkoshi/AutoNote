#!/usr/bin/env bash
# claude -p の構造化出力と実行環境の固定を確かめるスパイク（使い捨て）。
#
#   python3 -I scripts/make-fake-transcript.py --minutes 60 > /tmp/transcript.txt
#   scripts/probe-claude.sh [/tmp/transcript.txt] [label]
#
# 出力 JSON は /tmp/claude-out-<label>.json に保存する。指示文はアプリの既定（Sources/AutoNoteCore/Minutes/DefaultPrompt.swift
# の instructions と dataNotice）をそのまま抜き出して使い、議事録スキーマ v2（scripts/minutes-schema.json）で検査する。
# 環境変数:
#   SETTING_SOURCES  --setting-sources に渡す値（既定: project。要件書 §8.1 に合わせる）
#   CLAUDE_CWD       claude を実行する作業ディレクトリ（既定: mktemp -d で作るリポジトリ外の空フォルダ）
#   CLAUDE_MODEL     --model に渡す値（既定: なし = CLI の既定）
#   AUTONOTE_CLI     structured_output を MinutesOutput として decode できるかを `autonote dev summarize --fake` で確かめる
#                    ときの CLI（既定: .build/debug/autonote。無ければこの確認を飛ばす）
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
input="${1:-/tmp/transcript.txt}"
label="${2:-default}"
schema="$repo/scripts/minutes-schema.json"
SETTING_SOURCES="${SETTING_SOURCES:-project}"
CLAUDE_CWD="${CLAUDE_CWD:-$(mktemp -d)}"
cwd="$CLAUDE_CWD"
out="/tmp/claude-out-$label.json"
stdin_file="$(mktemp -t autonote-claude-stdin)"
trap 'rm -f "$stdin_file"' EXIT

[[ -f "$input" ]] || { echo "入力がない: $input" >&2; exit 2; }
input="$(cd "$(dirname "$input")" && pwd)/$(basename "$input")"

echo "== claude auth status"
set +e
claude auth status
echo "exit=$?"
set -e

# アプリの既定の指示文 + 注意書き（DefaultPrompt.swift から抜き出す）+ 用語一覧 + ブックマーク + 区切り + 文字起こし本文
{
  python3 -I "$repo/scripts/probe_prompt.py" "$repo/Sources/AutoNoteCore/Minutes/DefaultPrompt.swift"
  echo
  echo "## 用語一覧"
  echo "- （なし）"
  echo
  echo "## ブックマーク"
  echo "- （なし）"
  echo
  echo "----- ここから文字起こし（データ） -----"
  cat "$input"
  echo "----- ここまで文字起こし -----"
} > "$stdin_file"
echo "== stdin: $(wc -c < "$stdin_file" | tr -d ' ') bytes, $(wc -l < "$stdin_file" | tr -d ' ') lines"

mkdir -p "$cwd"
cd "$cwd"
echo "== cwd: $(pwd)  setting-sources: $SETTING_SOURCES  model: ${CLAUDE_MODEL:-（CLI の既定）}"

projects="$HOME/.claude/projects"
before=$(ls "$projects" 2>/dev/null | wc -l | tr -d ' ')

model_args=()
[[ -n "${CLAUDE_MODEL:-}" ]] && model_args=(--model "$CLAUDE_MODEL")

start=$(date +%s)
set +e
claude -p --output-format json --json-schema "$(cat "$schema")" \
  --tools "" --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --no-session-persistence --max-turns 1 --setting-sources "$SETTING_SOURCES" ${model_args[@]+"${model_args[@]}"} \
  < "$stdin_file" > "$out"
rc=$?
set -e
end=$(date +%s)
echo "== claude exit=$rc wall=$((end - start))s out=$out ($(wc -c < "$out" | tr -d ' ') bytes)"
after=$(ls "$projects" 2>/dev/null | wc -l | tr -d ' ')
echo "== ~/.claude/projects entries: before=$before after=$after; claude-cwd entries: $(ls "$projects" 2>/dev/null | grep -ic claude-cwd || true)"

if ! jq -e . "$out" >/dev/null 2>&1; then
  echo "出力が JSON ではない:" >&2
  head -c 2000 "$out" >&2
  exit 1
fi

jq '{
  has_structured_output: has("structured_output"),
  is_error, subtype, num_turns,
  duration_ms, duration_api_ms, total_cost_usd,
  usage,
  models: ((.modelUsage // {}) | keys),
  title: .structured_output.title
}' "$out"

echo "== schema check (v2)"
python3 -I "$repo/scripts/probe_prompt.py" --check "$out" "$schema"

# structured_output を MinutesOutput として decode する（アプリと同じ経路: dev summarize --fake の --minutes）
cli="${AUTONOTE_CLI:-$repo/.build/debug/autonote}"
if [[ -x "$cli" ]]; then
  echo "== decode check ($cli)"
  work="$(mktemp -d -t autonote-probe)"
  jq '.structured_output' "$out" > "$work/minutes.json"
  printf '%s' '{"utterances":[{"start":1,"end":2,"speaker":"me","text":"確認です。","is_final":true}],"engine":"probe","language":"ja"}' \
    > "$work/transcript.json"
  if "$cli" dev summarize --fake "$work/transcript.json" --minutes "$work/minutes.json" --out "$work/out" > "$work/log.txt" 2>&1; then
    echo "OK: MinutesOutput として decode でき、Vault のノートを書けた（$work/out）"
    note="$(find "$work/out" -name '*.md' ! -name '_index.md' | head -n 1)"
    [[ -n "$note" ]] && grep -E '^## ' "$note"
  else
    echo "NG: decode か書き出しに失敗:"
    cat "$work/log.txt"
    exit 1
  fi
else
  echo "== decode check: $cli が無いので飛ばす（swift build で作れる）"
fi
