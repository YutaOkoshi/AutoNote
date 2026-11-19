#!/usr/bin/env bash
# リリース署名の鍵まわり。鍵（「AutoNote Dev」の p12）の正は 1Password、GitHub には Environment「release」の Secrets に写しを置く。
# 値（p12・パスワード）は画面・ログ・ファイルに残さない（一時ファイルは 0700 のディレクトリに置き、終了時に消す）。
#
# 使い方:
#   scripts/signing.sh check <AutoNote.app> [<SHA-1>]
#       designated requirement が `identifier "<bundle id>" and certificate leaf = H"<SHA-1>"` か（既定は config.sh の
#       AUTONOTE_CERT_SHA1）。同梱の CLI とフレームワークも同じ証明書か。署名が strict に有効か。
#   scripts/signing.sh import-ci <キーチェーンのパス>
#       環境変数 AUTONOTE_SIGNING_P12_BASE64 / AUTONOTE_SIGNING_P12_PASSWORD の p12 を新しい一時キーチェーンに取り込み、
#       codesign が確認なしで使えるようにする。証明書の SHA-1 が期待値（AUTONOTE_EXPECT_CERT_SHA1、既定は
#       AUTONOTE_CERT_SHA1）と違えば失敗。SHA-1 を標準出力に 1 行で出す。release.yml の署名ジョブが使う。
#   scripts/signing.sh delete-keychain <キーチェーンのパス>
#   scripts/signing.sh selftest [<AutoNote.app>]
#       手元で release.yml と同じ手順を回す: 使い捨ての証明書を作り → import-ci → sign-app.sh → check、
#       さらに期待値違いの check が失敗することも確かめる。login キーチェーンと検索リストは変えない。
#   scripts/signing.sh export-to-1password
#       login キーチェーンの「AutoNote Dev」（証明書と秘密鍵）を p12 にして 1Password に保存し、GitHub の Environment
#       「release」の Secrets に入れる。要: `op` にサインイン済み（1Password アプリの CLI 連携）、`gh` にログイン済み。
#       鍵の書き出しで macOS がキーチェーンのパスワードを 1 回たずねる（秘密鍵の ACL は codesign だけを許すため）。
#       OP_VAULT（既定 Private）、OP_ITEM_PREFIX（既定「AutoNote release signing」）、GH_REPO（既定 YutaOkoshi/AutoNote）。
#   scripts/signing.sh import-login
#       1Password の p12 を login キーチェーンに取り込み、コード署名用に信頼する（別の Mac で手元とリリースを同じ証明書に
#       そろえるとき。管理者認証のダイアログが出る）。既に「AutoNote Dev」がある Mac では何もしない。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=config.sh
source "${ROOT}/scripts/config.sh"
BUNDLE_ID="${AUTONOTE_BUNDLE_ID}"
OP="${OP:-$(command -v op || echo /opt/homebrew/bin/op)}"
OP_VAULT="${OP_VAULT:-Private}"
OP_ITEM_PREFIX="${OP_ITEM_PREFIX:-AutoNote release signing}"
GH_REPO="${GH_REPO:-YutaOkoshi/AutoNote}"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
# Homebrew の openssl を優先（make-dev-cert.sh と同じ理由: security import が読める p12 を作るため）
OPENSSL="$(command -v /opt/homebrew/bin/openssl || command -v /usr/local/bin/openssl || command -v openssl)"

die() { echo "エラー: $*" >&2; exit 1; }
lower() { tr '[:upper:]' '[:lower:]'; }

private_dir() { (umask 077; mktemp -d "${TMPDIR:-/tmp}/autonote-signing.XXXXXX"); }

# OpenSSL 3 の既定は macOS の security import が読めないので、古い形式を明示する（LibreSSL は既定のまま）
pkcs12_compat() {
    if "${OPENSSL}" version | grep -q "^LibreSSL"; then return; fi
    printf '%s\n' -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
}

cmd_check() {
    local app="${1:?使い方: $0 check <AutoNote.app> [<SHA-1>]}" sha1
    sha1="$(lower <<<"${2:-${AUTONOTE_CERT_SHA1}}")"
    [[ -d "${app}" ]] || die "アプリが無い: ${app}"
    local want="identifier \"${BUNDLE_ID}\" and certificate leaf = H\"${sha1}\""
    local got cli fw
    got="$(codesign -d -r- "${app}" 2>&1 | sed -n 's/^designated => //p')"
    cli="$(codesign -d -r- "${app}/Contents/MacOS/autonote" 2>&1 | sed -n 's/^designated => //p')"
    fw="$(codesign -d -r- "${app}/Contents/Frameworks/whisper.framework" 2>&1 | sed -n 's/^designated => //p')"
    local problems=()
    [[ "${got}" == "${want}" ]] || problems+=("アプリの designated requirement が「${got:-なし}」（期待「${want}」）")
    [[ "${cli}" == "identifier \"${BUNDLE_ID}.cli\" and certificate leaf = H\"${sha1}\"" ]] \
        || problems+=("CLI の designated requirement が「${cli:-なし}」")
    [[ "${fw}" == *"certificate leaf = H\"${sha1}\""* ]] || problems+=("whisper.framework の designated requirement が「${fw:-なし}」")
    codesign --verify --strict "${app}" 2>/dev/null || problems+=("codesign --verify --strict が失敗")
    if [[ ${#problems[@]} -gt 0 ]]; then
        printf '署名の検査に失敗: %s\n' "${problems[@]}" >&2
        exit 1
    fi
    echo "署名の検査に合格: ${want}"
}

cmd_import_ci() {
    local keychain="${1:?使い方: $0 import-ci <キーチェーンのパス>}"
    [[ -n "${AUTONOTE_SIGNING_P12_BASE64:-}" && -n "${AUTONOTE_SIGNING_P12_PASSWORD:-}" ]] \
        || die "署名用の Secrets（AUTONOTE_SIGNING_P12_BASE64 / AUTONOTE_SIGNING_P12_PASSWORD）がありません。Environment「release」の Secrets を確かめてください（fork では署名できません）"
    local expect work kc_pass sha1
    expect="$(lower <<<"${AUTONOTE_EXPECT_CERT_SHA1:-${AUTONOTE_CERT_SHA1}}")"
    work="$(private_dir)"
    # shellcheck disable=SC2064
    trap "rm -rf '${work}'" RETURN
    kc_pass="$("${OPENSSL}" rand -hex 24)"
    security create-keychain -p "${kc_pass}" "${keychain}"
    security set-keychain-settings -lut 3600 "${keychain}"
    security unlock-keychain -p "${kc_pass}" "${keychain}"
    printf '%s' "${AUTONOTE_SIGNING_P12_BASE64}" | base64 --decode >"${work}/id.p12"
    security import "${work}/id.p12" -k "${keychain}" -f pkcs12 -P "${AUTONOTE_SIGNING_P12_PASSWORD}" \
        -T /usr/bin/codesign >/dev/null
    rm -f "${work}/id.p12"
    # codesign がダイアログなしで秘密鍵を使えるようにする
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${kc_pass}" "${keychain}" >/dev/null
    sha1="$(security find-identity -p codesigning "${keychain}" | awk '/^ *[0-9]+\)/{print $2; exit}' | lower)"
    [[ -n "${sha1}" ]] || die "取り込んだ p12 にコード署名用の識別子がありません"
    [[ "${sha1}" == "${expect}" ]] || die "取り込んだ証明書の SHA-1 ${sha1} が期待値 ${expect} と違います（scripts/config.sh の AUTONOTE_CERT_SHA1）"
    echo "${sha1}"
}

cmd_delete_keychain() {
    local keychain="${1:?使い方: $0 delete-keychain <キーチェーンのパス>}"
    [[ -e "${keychain}" ]] && security delete-keychain "${keychain}"
    return 0
}

cmd_selftest() {
    local app="${1:-${ROOT}/build/AutoNote.app}"
    [[ -d "${app}" ]] || die "アプリが無い: ${app}（scripts/build-app.sh で作る）"
    local work; work="$(private_dir)"
    local keychain="${work}/selftest.keychain-db"
    # shellcheck disable=SC2064
    trap "security delete-keychain '${keychain}' 2>/dev/null; rm -rf '${work}'" EXIT
    cat >"${work}/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = codesign_ext
prompt = no
[ dn ]
CN = AutoNote Signing Selftest
[ codesign_ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
    "${OPENSSL}" req -x509 -newkey rsa:2048 -days 1 -nodes -config "${work}/cert.cnf" \
        -keyout "${work}/key.pem" -out "${work}/cert.pem" 2>/dev/null
    local pass sha1 identity
    pass="$("${OPENSSL}" rand -hex 16)"
    # shellcheck disable=SC2046
    "${OPENSSL}" pkcs12 -export $(pkcs12_compat) -inkey "${work}/key.pem" -in "${work}/cert.pem" \
        -name "AutoNote Signing Selftest" -passout "pass:${pass}" -out "${work}/id.p12"
    rm -f "${work}/key.pem"
    sha1="$("${OPENSSL}" x509 -in "${work}/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | lower)"
    echo "使い捨ての証明書: SHA-1 ${sha1}"
    identity="$(AUTONOTE_SIGNING_P12_BASE64="$(base64 -i "${work}/id.p12")" AUTONOTE_SIGNING_P12_PASSWORD="${pass}" \
        AUTONOTE_EXPECT_CERT_SHA1="${sha1}" "${BASH_SOURCE[0]}" import-ci "${keychain}")"
    rm -f "${work}/id.p12"
    echo "import-ci: 識別子 ${identity}"
    ditto "${app}" "${work}/AutoNote.app"
    AUTONOTE_CODESIGN_KEYCHAIN="${keychain}" "${ROOT}/scripts/sign-app.sh" "${work}/AutoNote.app" "${identity}" >/dev/null 2>&1 \
        || die "sign-app.sh が一時キーチェーンの識別子で署名できない"
    echo "sign-app.sh: 一時キーチェーンで署名した"
    "${BASH_SOURCE[0]}" check "${work}/AutoNote.app" "${sha1}"
    if "${BASH_SOURCE[0]}" check "${work}/AutoNote.app" "${AUTONOTE_CERT_SHA1}" 2>/dev/null; then
        die "期待値違い（AUTONOTE_CERT_SHA1）の check が通ってしまった"
    fi
    echo "期待値違いの check は失敗する（検査が効いている）"
    if AUTONOTE_SIGNING_P12_BASE64="" AUTONOTE_SIGNING_P12_PASSWORD="" "${BASH_SOURCE[0]}" import-ci "${work}/none.keychain-db" 2>/dev/null; then
        die "Secrets なしの import-ci が通ってしまった"
    fi
    echo "Secrets なしの import-ci は失敗する（fork などではリリースが止まる）"
    echo "selftest: 合格"
}

require_op() {
    [[ -x "${OP}" ]] || die "1Password CLI（op）がありません"
    "${OP}" whoami >/dev/null 2>&1 \
        || die "op がサインインしていません。1Password アプリの 設定 → 開発者 → 「1Password CLI と連携」をオンにして、もう一度実行してください"
}

cmd_export_to_1password() {
    require_op
    gh auth status >/dev/null 2>&1 || die "gh がログインしていません"
    security find-certificate -c "${AUTONOTE_CERT_NAME}" -Z "${LOGIN_KEYCHAIN}" 2>/dev/null | grep -qi "SHA-1 hash: ${AUTONOTE_CERT_SHA1}" \
        || die "login キーチェーンに SHA-1 ${AUTONOTE_CERT_SHA1} の「${AUTONOTE_CERT_NAME}」がありません"
    local work; work="$(private_dir)"
    # shellcheck disable=SC2064
    trap "rm -rf '${work}'" EXIT
    local export_pass p12_pass
    export_pass="$("${OPENSSL}" rand -hex 24)"
    p12_pass="$("${OPENSSL}" rand -base64 30 | tr -d '/+=' | head -c 32)"
    echo "login キーチェーンから書き出します（macOS がキーチェーンのパスワードを 1 回たずねます）"
    # security export は種類ごとにすべて書き出すので、あとで「AutoNote Dev」の証明書と対の鍵だけを取り出す
    security export -k "${LOGIN_KEYCHAIN}" -t identities -f pkcs12 -P "${export_pass}" -o "${work}/all.p12" >/dev/null
    "${OPENSSL}" pkcs12 -in "${work}/all.p12" -passin "pass:${export_pass}" -nokeys -clcerts 2>/dev/null >"${work}/certs.pem" \
        || "${OPENSSL}" pkcs12 -legacy -in "${work}/all.p12" -passin "pass:${export_pass}" -nokeys -clcerts >"${work}/certs.pem"
    "${OPENSSL}" pkcs12 -in "${work}/all.p12" -passin "pass:${export_pass}" -nocerts -nodes 2>/dev/null >"${work}/keys.pem" \
        || "${OPENSSL}" pkcs12 -legacy -in "${work}/all.p12" -passin "pass:${export_pass}" -nocerts -nodes >"${work}/keys.pem"
    rm -f "${work}/all.p12"
    # 期待の SHA-1 の証明書を 1 枚、その公開鍵と一致する秘密鍵を 1 つ選ぶ
    awk -v dir="${work}" '/BEGIN CERTIFICATE/{n++; f=dir "/c" n ".pem"} f{print > f} /END CERTIFICATE/{f=""}' "${work}/certs.pem"
    awk -v dir="${work}" '/BEGIN .*PRIVATE KEY/{n++; f=dir "/k" n ".pem"} f{print > f} /END .*PRIVATE KEY/{f=""}' "${work}/keys.pem"
    rm -f "${work}/certs.pem" "${work}/keys.pem"
    local cert="" key="" c k pub
    for c in "${work}"/c*.pem; do
        [[ "$("${OPENSSL}" x509 -in "${c}" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | lower)" == "${AUTONOTE_CERT_SHA1}" ]] && cert="${c}"
    done
    [[ -n "${cert}" ]] || die "書き出しの中に SHA-1 ${AUTONOTE_CERT_SHA1} の証明書がありません"
    pub="$("${OPENSSL}" x509 -in "${cert}" -noout -pubkey)"
    for k in "${work}"/k*.pem; do
        [[ "$("${OPENSSL}" pkey -in "${k}" -pubout 2>/dev/null)" == "${pub}" ]] && key="${k}"
    done
    [[ -n "${key}" ]] || die "証明書と対になる秘密鍵が書き出しの中にありません"
    # shellcheck disable=SC2046
    "${OPENSSL}" pkcs12 -export $(pkcs12_compat) -inkey "${key}" -in "${cert}" -name "${AUTONOTE_CERT_NAME}" \
        -passout "pass:${p12_pass}" -out "${work}/autonote-signing.p12"
    rm -f "${work}"/k*.pem
    # 1Password（正）: p12 は Document、パスワードは Password。パスワードはファイル経由で渡し、コマンドラインに出さない
    "${OP}" document create "${work}/autonote-signing.p12" --vault "${OP_VAULT}" \
        --title "${OP_ITEM_PREFIX} (p12)" --file-name "autonote-signing.p12" >/dev/null
    printf '{"title": "%s (p12 password)", "category": "PASSWORD", "fields": [{"id": "password", "type": "CONCEALED", "purpose": "PASSWORD", "value": "%s"}], "notesPlain": "AutoNote のリリース署名用 p12（%s, SHA-1 %s）のパスワード。GitHub Environment release の AUTONOTE_SIGNING_P12_PASSWORD と同じ。"}' \
        "${OP_ITEM_PREFIX}" "${p12_pass}" "${AUTONOTE_CERT_NAME}" "${AUTONOTE_CERT_SHA1}" >"${work}/item.json"
    "${OP}" item create --vault "${OP_VAULT}" --template "${work}/item.json" >/dev/null
    rm -f "${work}/item.json"
    echo "1Password に保存: 「${OP_ITEM_PREFIX} (p12)」「${OP_ITEM_PREFIX} (p12 password)」（${OP_VAULT}）"
    # GitHub: Environment「release」の Secrets（値は標準入力で渡す）
    base64 -i "${work}/autonote-signing.p12" | tr -d '\n' | gh secret set AUTONOTE_SIGNING_P12_BASE64 --env release --repo "${GH_REPO}"
    printf '%s' "${p12_pass}" | gh secret set AUTONOTE_SIGNING_P12_PASSWORD --env release --repo "${GH_REPO}"
    echo "GitHub の Environment「release」に Secrets を入れた: AUTONOTE_SIGNING_P12_BASE64, AUTONOTE_SIGNING_P12_PASSWORD"
}

cmd_import_login() {
    require_op
    if security find-identity -p codesigning "${LOGIN_KEYCHAIN}" | grep -qi "${AUTONOTE_CERT_SHA1}"; then
        echo "login キーチェーンに SHA-1 ${AUTONOTE_CERT_SHA1} の「${AUTONOTE_CERT_NAME}」があります。何もしません"
        return 0
    fi
    if security find-certificate -c "${AUTONOTE_CERT_NAME}" "${LOGIN_KEYCHAIN}" >/dev/null 2>&1; then
        die "login キーチェーンに別の「${AUTONOTE_CERT_NAME}」があります。名前が重なると codesign が識別子を選べないので、キーチェーンアクセスで削除してから実行してください（その Mac で手元ビルドに与えた許可は一度外れます）"
    fi
    local work; work="$(private_dir)"
    # shellcheck disable=SC2064
    trap "rm -rf '${work}'" EXIT
    "${OP}" document get "${OP_ITEM_PREFIX} (p12)" --vault "${OP_VAULT}" --out-file "${work}/id.p12" >/dev/null
    local pass; pass="$("${OP}" read "op://${OP_VAULT}/${OP_ITEM_PREFIX} (p12 password)/password")"
    security import "${work}/id.p12" -k "${LOGIN_KEYCHAIN}" -f pkcs12 -P "${pass}" -T /usr/bin/codesign
    rm -f "${work}/id.p12"
    security find-certificate -c "${AUTONOTE_CERT_NAME}" -p "${LOGIN_KEYCHAIN}" >"${work}/cert.pem"
    security add-trusted-cert -d -r trustRoot -p codeSign -k "${LOGIN_KEYCHAIN}" "${work}/cert.pem"
    security find-identity -v -p codesigning "${LOGIN_KEYCHAIN}" | grep "${AUTONOTE_CERT_NAME}"
}

case "${1:-}" in
    check) shift; cmd_check "$@" ;;
    import-ci) shift; cmd_import_ci "$@" ;;
    delete-keychain) shift; cmd_delete_keychain "$@" ;;
    selftest) shift; cmd_selftest "$@" ;;
    export-to-1password) shift; cmd_export_to_1password ;;
    import-login) shift; cmd_import_login ;;
    *) sed -n '2,27p' "$0" >&2; exit 64 ;;
esac
