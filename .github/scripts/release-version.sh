#!/usr/bin/env bash
# CI 用: Resources/Info.plist の CFBundleShortVersionString を読み、v<version> のタグが origin に無いか調べる。
# 使い方: .github/scripts/release-version.sh [Info.plist のパス]
# 出力（GITHUB_OUTPUT があればそこへ、無ければ標準出力へ）: version=<x.y.z> / tag=v<x.y.z> / release=true|false
set -euo pipefail

plist="${1:-Resources/Info.plist}"
# macOS 以外（ubuntu ランナー）でも読めるよう python3 の plistlib を使う
version="$(python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))["CFBundleShortVersionString"])' "${plist}")"
if [[ ! "${version}" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "::error::CFBundleShortVersionString が x.y.z 形式でない: ${version}" >&2
    exit 1
fi
# アプリ内の版（AutoNoteVersion.current）が plist と揃っていなければリリースしない（E2E 5b と同じ読み方）
swift_version="$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' Sources/AutoNoteCore/AutoNoteVersion.swift)"
if [[ "${swift_version}" != "${version}" ]]; then
    echo "::error::Info.plist の版 ${version} と AutoNoteVersion.current ${swift_version} が違う" >&2
    exit 1
fi
tag="v${version}"

# ls-remote --exit-code は、一致が無いとき 2、通信などの失敗では別の値を返す
status=0
git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null || status=$?
case "${status}" in
    0) release=false; echo "タグ ${tag} は既にある。リリースしない" >&2 ;;
    2) release=true;  echo "タグ ${tag} が無い。リリースする" >&2 ;;
    *) echo "::error::git ls-remote が失敗した（exit ${status}）" >&2; exit "${status}" ;;
esac

out="${GITHUB_OUTPUT:-/dev/stdout}"
{
    echo "version=${version}"
    echo "tag=${tag}"
    echo "release=${release}"
} >> "${out}"
