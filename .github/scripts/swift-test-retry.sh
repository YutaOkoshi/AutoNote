#!/usr/bin/env bash
# CI 用: swift test を走らせ、失敗したら 1 回だけ再実行する。
# 壁時計に依存する既存テストが負荷で落ちることがあるため（--filter で除外はしない）。
# 並列実行そのものが負荷になり、毎回別の時間依存テストが 1 つ落ちることがある（手元で確認）ので、
# 再実行は --no-parallel で直列に走らせる（手元では 900 件が約 1 分で通る）。
set -uo pipefail

if swift test "$@"; then
    exit 0
fi
echo "::warning::swift test が失敗したので、直列（--no-parallel）で 1 回だけ再実行する"
swift test --no-parallel "$@"
