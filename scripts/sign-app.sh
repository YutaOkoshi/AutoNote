#!/usr/bin/env bash
# 組み立て済みの AutoNote.app を中から外へ署名する（--deep は使わない）。build-app.sh と release.yml の署名ジョブが使う。
# 使い方: scripts/sign-app.sh <AutoNote.app> <identity>
#   identity は証明書名（「AutoNote Dev」）・SHA-1・`-`（アドホック）のどれか
#   AUTONOTE_CODESIGN_KEYCHAIN  identity を探すキーチェーン（release.yml と scripts/signing.sh selftest の一時キーチェーン）。
#                               指定するとそのキーチェーンだけを見る（ユーザーのキーチェーンの検索リストは変えない）
set -euo pipefail

APP="${1:?使い方: $0 <AutoNote.app> <identity>}"
IDENTITY="${2:?使い方: $0 <AutoNote.app> <identity>}"
# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
BUNDLE_ID="${AUTONOTE_BUNDLE_ID}"

SIGN=(codesign --force --sign "${IDENTITY}" --timestamp=none)
if [[ -n "${AUTONOTE_CODESIGN_KEYCHAIN:-}" ]]; then
    SIGN+=(--keychain "${AUTONOTE_CODESIGN_KEYCHAIN}")
fi

# フレームワークを先に同じ証明書で署名する
"${SIGN[@]}" "${APP}/Contents/Frameworks/whisper.framework"
# 同梱 CLI はリンカのアドホック署名のままだとバンドル署名の対象外になるので、先に同じ証明書で署名する
"${SIGN[@]}" --identifier "${BUNDLE_ID}.cli" "${APP}/Contents/MacOS/autonote"
"${SIGN[@]}" --identifier "${BUNDLE_ID}" "${APP}"
codesign -dv --verbose=2 "${APP}"
codesign --verify --strict "${APP}"
