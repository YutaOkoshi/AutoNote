#!/usr/bin/env bash
# 自己署名のコード署名証明書「AutoNote Dev」をログインキーチェーンに作り、コード署名用に信頼する。
# 冪等: 信頼済みの識別子があれば何もしない。証明書は取り込み済みで信頼設定だけ済んでいない
# （管理者認証ダイアログを取り消した等）場合は、作り直さずに信頼設定だけやり直す。
# 同名の証明書が 2 枚になると codesign --sign "AutoNote Dev" が ambiguous で失敗するため。
set -euo pipefail

# shellcheck source=config.sh
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
CERT_NAME="${AUTONOTE_CERT_NAME}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

# 信頼済みの（有効な）コード署名識別子として存在するか
has_valid_identity() {
    security find-identity -v -p codesigning "${KEYCHAIN}" | grep -q "\"${CERT_NAME}\""
}

# 秘密鍵と対になった識別子として存在するか（信頼の有無は問わない）
has_identity() {
    security find-identity -p codesigning "${KEYCHAIN}" | grep -q "\"${CERT_NAME}\""
}

# キーチェーン内の、ラベルが CERT_NAME と完全一致する証明書の枚数
# （find-certificate -c は部分一致なのでラベルで絞る）
cert_count() {
    { security find-certificate -a -c "${CERT_NAME}" "${KEYCHAIN}" 2>/dev/null || true; } \
        | grep -c "\"labl\"<blob>=\"${CERT_NAME}\"" || true
}

if has_valid_identity; then
    echo "「${CERT_NAME}」は既にあります。何もしません。"
    security find-identity -v -p codesigning "${KEYCHAIN}" | grep "${CERT_NAME}"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

COUNT="$(cert_count)"
if [ "${COUNT}" -gt 1 ]; then
    echo "エラー: 「${CERT_NAME}」の証明書がキーチェーンに ${COUNT} 枚あります。codesign が識別子を一つに決められません。" >&2
    echo "キーチェーンアクセスで余分なものを削除してから再実行してください:" >&2
    security find-certificate -a -c "${CERT_NAME}" -Z "${KEYCHAIN}" | grep "SHA-1" >&2 || true
    exit 1
fi

if [ "${COUNT}" -eq 1 ]; then
    if ! has_identity; then
        echo "エラー: 「${CERT_NAME}」の証明書はありますが、対になる秘密鍵がありません。署名に使えません。" >&2
        echo "キーチェーンアクセスでこの証明書を削除してから再実行してください。" >&2
        exit 1
    fi
    echo "「${CERT_NAME}」は取り込み済みですが信頼設定がありません。信頼設定だけやり直します。"
    security find-certificate -c "${CERT_NAME}" -p "${KEYCHAIN}" > "${WORK}/cert.pem"
    security add-trusted-cert -d -r trustRoot -p codeSign -k "${KEYCHAIN}" "${WORK}/cert.pem"
    security find-identity -v -p codesigning "${KEYCHAIN}" | grep "${CERT_NAME}"
    exit 0
fi

# ここから先は証明書が 1 枚も無いときだけ: 生成 → 取り込み → 信頼

# Homebrew の openssl を優先（システムの LibreSSL は pkcs12 の既定暗号が古く security import で失敗しやすい）
OPENSSL="$(command -v /usr/local/bin/openssl || command -v /opt/homebrew/bin/openssl || command -v openssl)"

cat > "${WORK}/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = codesign_ext
prompt = no

[ dn ]
CN = ${CERT_NAME}

[ codesign_ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

"${OPENSSL}" req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -subj "/CN=${CERT_NAME}" \
    -config "${WORK}/cert.cnf" \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem"

# p12 は一時ファイルなので使い捨てのパスワードで包む（空パスワードだと security import が
# 「MAC verification failed」で失敗する）
P12_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24 || true)"

# OpenSSL 3 以降の既定（AES-256 / PBKDF2）は macOS の security import が読めないため、
# 古い形式（3DES + SHA1 MAC）を明示する。LibreSSL は既定がこの形式なので付けない。
PKCS12_COMPAT=()
if ! "${OPENSSL}" version | grep -q "^LibreSSL"; then
    PKCS12_COMPAT=(-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1)
fi
"${OPENSSL}" pkcs12 -export "${PKCS12_COMPAT[@]}" \
    -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
    -name "${CERT_NAME}" -passout "pass:${P12_PASS}" -out "${WORK}/cert.p12"

security import "${WORK}/cert.p12" -k "${KEYCHAIN}" -P "${P12_PASS}" -T /usr/bin/codesign

security add-trusted-cert -d -r trustRoot -p codeSign -k "${KEYCHAIN}" "${WORK}/cert.pem"

security find-identity -v -p codesigning "${KEYCHAIN}" | grep "${CERT_NAME}"
