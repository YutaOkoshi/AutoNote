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

CERT_NAME="AutoNote Dev"
BUNDLE_ID="com.yutaokoshi.autonote"
APP="${ROOT}/build/AutoNote.app"

if ! security find-identity -v -p codesigning | grep -q "\"${CERT_NAME}\""; then
    "${ROOT}/scripts/make-dev-cert.sh"
fi

swift build -c "${CONF}" --product AutoNoteApp
swift build -c "${CONF}" --product autonote
BIN_DIR="$(swift build -c "${CONF}" --show-bin-path)"

rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_DIR}/AutoNoteApp" "${APP}/Contents/MacOS/AutoNoteApp"
cp "${BIN_DIR}/autonote" "${APP}/Contents/MacOS/autonote"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"

# 同梱 CLI はリンカのアドホック署名のままだとバンドル署名の対象外になるので、先に同じ証明書で署名する
codesign --force --sign "${CERT_NAME}" --identifier "${BUNDLE_ID}.cli" --timestamp=none "${APP}/Contents/MacOS/autonote"
codesign --force --sign "${CERT_NAME}" --identifier "${BUNDLE_ID}" --timestamp=none "${APP}"
codesign -dv --verbose=2 "${APP}"
codesign --verify --strict "${APP}"
