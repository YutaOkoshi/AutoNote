#!/usr/bin/env bash
# CI 用: swift test を走らせ、失敗したら 1 回だけ再実行する。
# 0.8.2 でテストの合否を実時間で決めるのをやめたので、1 回目の並列実行で通るのが期待値。再実行は保険で、
# --no-parallel で直列に走らせる。下の警告がログに出たら 1 回目は落ちている: ジョブが緑でも、落ちたテストを
# 直す（docs/development.md「開発の約束事」）。
set -uo pipefail

if swift test "$@"; then
    exit 0
fi
echo "::warning::swift test が失敗したので、直列（--no-parallel）で 1 回だけ再実行する"
swift test --no-parallel "$@"
