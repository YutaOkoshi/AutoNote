#!/usr/bin/env bash
# CI 用: swift test を走らせ、失敗したら 1 回だけ再実行する。
# 壁時計に依存する既存テストが CI の負荷で落ちることがあるため（--filter で除外はしない）。
set -uo pipefail

if swift test "$@"; then
    exit 0
fi
echo "::warning::swift test が失敗したので 1 回だけ再実行する"
swift test "$@"
