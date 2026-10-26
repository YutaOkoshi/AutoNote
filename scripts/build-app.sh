#!/usr/bin/env bash
# AutoNote.app を組み立てて「AutoNote Dev」で署名する。
# 使い方: scripts/build-app.sh [debug|release]   （既定は debug）
set -euo pipefail

CONF="${1:-debug}"
case "${CONF}" in
    debug|release) ;;
    *) echo "使い方: $0 [debug|release]" >&2; exit 64 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# shellcheck source=config.sh
source "${ROOT}/scripts/config.sh"
CERT_NAME="${AUTONOTE_CERT_NAME}"
BUNDLE_ID="${AUTONOTE_BUNDLE_ID}"
APP="${ROOT}/build/AutoNote.app"

if ! security find-identity -v -p codesigning | grep -q "\"${CERT_NAME}\""; then
    "${ROOT}/scripts/make-dev-cert.sh"
fi

# whisper.cpp の XCFramework（Package.swift の binaryTarget）が無ければ先にソースから作る
if [[ ! -f "${ROOT}/tools/whisper.xcframework/Info.plist" ]]; then
    "${ROOT}/scripts/build-whisper-xcframework.sh"
fi

swift build -c "${CONF}" --product AutoNoteApp
swift build -c "${CONF}" --product autonote
BIN_DIR="$(swift build -c "${CONF}" --show-bin-path)"

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/AutoNoteApp" "${APP}/Contents/MacOS/AutoNoteApp"
cp "${BIN_DIR}/autonote" "${APP}/Contents/MacOS/autonote"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"
PLIST_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Contents/Info.plist")"
if [[ "${PLIST_BUNDLE_ID}" != "${BUNDLE_ID}" ]]; then
    echo "エラー: Info.plist の CFBundleIdentifier (${PLIST_BUNDLE_ID}) が scripts/config.sh の AUTONOTE_BUNDLE_ID (${BUNDLE_ID}) と違います。" >&2
    exit 1
fi

# whisper.cpp の XCFramework（macos-arm64_x86_64 スライス）を同梱し、実行ファイルから @rpath で引けるようにする
WHISPER_FW="${BIN_DIR}/whisper.framework"
if [[ ! -d "${WHISPER_FW}" ]]; then
    WHISPER_FW="${ROOT}/tools/whisper.xcframework/macos-arm64_x86_64/whisper.framework"
fi
if [[ -z "${WHISPER_FW}" || ! -d "${WHISPER_FW}" ]]; then
    echo "whisper.framework が見つからない" >&2
    exit 1
fi
mkdir -p "${APP}/Contents/Frameworks"
ditto "${WHISPER_FW}" "${APP}/Contents/Frameworks/whisper.framework"
for exe in "${APP}/Contents/MacOS/AutoNoteApp" "${APP}/Contents/MacOS/autonote"; do
    if ! otool -l "${exe}" | grep -q "path @executable_path/../Frameworks "; then
        install_name_tool -add_rpath @executable_path/../Frameworks "${exe}"
    fi
done

# 中身から外へ順に署名する（--deep は使わない）。フレームワークを先に同じ証明書で署名する
codesign --force --sign "${CERT_NAME}" --timestamp=none "${APP}/Contents/Frameworks/whisper.framework"
# 同梱 CLI はリンカのアドホック署名のままだとバンドル署名の対象外になるので、先に同じ証明書で署名する
codesign --force --sign "${CERT_NAME}" --identifier "${BUNDLE_ID}.cli" --timestamp=none "${APP}/Contents/MacOS/autonote"
codesign --force --sign "${CERT_NAME}" --identifier "${BUNDLE_ID}" --timestamp=none "${APP}"
codesign -dv --verbose=2 "${APP}"
codesign --verify --strict "${APP}"
