#!/usr/bin/env bash
# CI 用: 指定の Xcode を選び（無ければイメージ既定の Xcode のまま）、Swift 6.3 以上か確かめる。
# 使い方: .github/scripts/select-xcode.sh [/Applications/Xcode_26.6.app]
# 選んだ Xcode のバージョンを GITHUB_ENV の AUTONOTE_XCODE_VERSION に書く（キャッシュキーに使う）。
set -euo pipefail

want="${1:-/Applications/Xcode_26.6.app}"
if [[ -d "${want}" ]]; then
    sudo xcode-select -s "${want}/Contents/Developer"
else
    echo "::warning::${want} が無いので既定の Xcode（$(xcode-select -p)）を使う"
fi

xcodebuild -version
swift --version
xcode_version="$(xcodebuild -version | sed -n 's/^Xcode //p')"
swift_version="$(swift --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)"
if [[ -z "${swift_version}" ]]; then
    echo "::error::Swift のバージョンが読めない"
    exit 1
fi
major="${swift_version%%.*}"
minor="${swift_version#*.}"
if (( major < 6 || (major == 6 && minor < 3) )); then
    echo "::error::Swift 6.3 以上が要る（今は ${swift_version}）。Xcode 26.4 以降を選ぶ"
    exit 1
fi
echo "Xcode ${xcode_version} / Swift ${swift_version}"
if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "AUTONOTE_XCODE_VERSION=${xcode_version}" >> "${GITHUB_ENV}"
fi
