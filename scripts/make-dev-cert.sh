#!/usr/bin/env bash
# 自己署名のコード署名証明書「AutoNote Dev」をログインキーチェーンに作り、コード署名用に信頼する。
# 既に有効な識別子として存在すれば何もしない。
set -euo pipefail

CERT_NAME="AutoNote Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"${CERT_NAME}\""; then
    echo "「${CERT_NAME}」は既にあります。何もしません。"
    security find-identity -v -p codesigning | grep "${CERT_NAME}"
    exit 0
fi

# Homebrew の openssl を優先（システムの LibreSSL は pkcs12 の既定暗号が古く security import で失敗しやすい）
OPENSSL="$(command -v /usr/local/bin/openssl || command -v /opt/homebrew/bin/openssl || command -v openssl)"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

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

security find-identity -v -p codesigning | grep "${CERT_NAME}"
