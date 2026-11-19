#!/usr/bin/env bash
# リリース署名の鍵まわり。鍵（「AutoNote Dev」の p12）の正は 1Password、GitHub には Environment「release」の Secrets に写しを置く。
# 値（p12・パスワード）は画面・ログに出さない。長く使うパスワード（p12 のもの）はコマンドラインにも出さない:
#   - openssl には環境変数で渡す（-passin/-passout env:…）。復号した鍵はパイプの中だけを通り、ファイルにしない
#   - security import は -P でしか受け取れないので、使い捨てのパスワードで包み直した p12 を渡す（引数に一瞬出るのは
#     その使い捨ての値だけで、包み直した p12 は取り込んだらすぐ消す）。一時キーチェーンのパスワードも使い捨て
#   - op には標準入力かテンプレートのファイル（0700 のディレクトリ）で渡す
#   一時ファイルは 0700 のディレクトリに置き、終了時に消す（SIGKILL では残りうる。中身は暗号化した p12 だけ）。
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
#       「release」の Secrets に入れる。要: `op` にサインイン済み（1Password アプリの CLI 連携）、`gh` にログイン済み、swift。
#       書き出すのはこの 1 件だけ（scripts/export-identity.swift。`security export` はすべての identity を書き出すため使わない）。
#       鍵の書き出しで macOS がキーチェーンのパスワードを 1 回たずねる（秘密鍵の ACL は codesign だけを許すため）。
#       OP_VAULT（既定 Personal。無ければ保管庫の一覧を出して止まる）、OP_ITEM_PREFIX（既定「AutoNote release signing」）、GH_REPO（既定 YutaOkoshi/AutoNote）。
#   scripts/signing.sh import-login
#       1Password の p12 を login キーチェーンに取り込み、コード署名用に信頼する（別の Mac で手元とリリースを同じ証明書に
#       そろえるとき。管理者認証のダイアログが出る）。既に「AutoNote Dev」がある Mac では何もしない。
#   op を使う入口（export-to-1password / import-login）は最初に 1Password アプリの承認ダイアログを出す（`op whoami` は
#   ダイアログを出さず、連携済みでも新しいプロセスでは失敗するため `op vault list` で確かめる）。承認されないと約 60 秒で止まる。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=config.sh
source "${ROOT}/scripts/config.sh"
BUNDLE_ID="${AUTONOTE_BUNDLE_ID}"
OP="${OP:-$(command -v op || echo /opt/homebrew/bin/op)}"
OP_VAULT="${OP_VAULT:-Personal}"
OP_ITEM_PREFIX="${OP_ITEM_PREFIX:-AutoNote release signing}"
GH_REPO="${GH_REPO:-YutaOkoshi/AutoNote}"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
# Homebrew の openssl を優先（make-dev-cert.sh と同じ理由: security import が読める p12 を作るため）
OPENSSL="$(command -v /opt/homebrew/bin/openssl || command -v /usr/local/bin/openssl || command -v openssl)"

die() { echo "エラー: $*" >&2; exit 1; }
lower() { tr '[:upper:]' '[:lower:]'; }
sha1_of_pem() { "${OPENSSL}" x509 -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | lower; }

private_dir() { (umask 077; mktemp -d "${TMPDIR:-/tmp}/autonote-signing.XXXXXX"); }

# OpenSSL 3 の既定は macOS の security import が読めないので、古い形式を明示する（LibreSSL は既定のまま）
pkcs12_compat() {
    if "${OPENSSL}" version | grep -q "^LibreSSL"; then return; fi
    printf '%s\n' -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
}

# p12_pem <p12> <パスワードの環境変数名> [openssl の追加の引数…]: 中身を PEM で標準出力へ（パイプで次へ渡すだけにする）。
# macOS の書き出し（RC2-40）は OpenSSL 3 以降では -legacy が要る
p12_pem() {
    local file="$1" var="$2"
    shift 2
    "${OPENSSL}" pkcs12 -in "${file}" -passin "env:${var}" -nodes "$@" 2>/dev/null \
        || "${OPENSSL}" pkcs12 -legacy -in "${file}" -passin "env:${var}" -nodes "$@" 2>/dev/null
}

# repack_p12 <元の p12> <元のパスワードの環境変数名> <出力> <新しいパスワードの環境変数名> <名前>:
# security import が読める形式（pkcs12_compat）で、新しいパスワードで包み直す。平文の鍵はプロセス置換のパイプの中
# だけを通る（here-string や一時ファイルは使わない: bash は here-string を一時ファイルに書く）。鍵と証明書は別の
# パイプで渡す（openssl は -in を 2 回読むので、1 本のパイプでは証明書を読めない）
repack_p12() {
    # shellcheck disable=SC2046
    "${OPENSSL}" pkcs12 -export $(pkcs12_compat) -name "$5" -passout "env:$4" -out "$3" \
        -inkey <(p12_pem "$1" "$2" -nocerts) -in <(p12_pem "$1" "$2" -nokeys -clcerts) \
        || die "p12 を開けません（パスワードが違うか、形式が読めない）"
}

# import_p12 <p12> <パスワードの環境変数名> <キーチェーン>: 使い捨てのパスワードで包み直してから取り込む
import_p12() {
    local work="$(dirname "$1")"
    AUTONOTE_ONCE="$("${OPENSSL}" rand -hex 24)"
    export AUTONOTE_ONCE
    repack_p12 "$1" "$2" "${work}/once.p12" AUTONOTE_ONCE "${AUTONOTE_CERT_NAME}"
    security import "${work}/once.p12" -k "$3" -f pkcs12 -P "${AUTONOTE_ONCE}" -T /usr/bin/codesign >/dev/null
    rm -f "${work}/once.p12"
    unset AUTONOTE_ONCE
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
    # EXIT: die（exit）では RETURN の trap は動かない。import-ci は単独のプロセスとして呼ぶ
    # shellcheck disable=SC2064
    trap "rm -rf '${work}'" EXIT
    # 一時キーチェーンのパスワードは使い捨て（このジョブの中だけ。security に -P/-p 以外の渡し方は無い）
    kc_pass="$("${OPENSSL}" rand -hex 24)"
    security create-keychain -p "${kc_pass}" "${keychain}"
    security set-keychain-settings -lut 3600 "${keychain}"
    security unlock-keychain -p "${kc_pass}" "${keychain}"
    printf '%s' "${AUTONOTE_SIGNING_P12_BASE64}" | base64 --decode >"${work}/id.p12"
    import_p12 "${work}/id.p12" AUTONOTE_SIGNING_P12_PASSWORD "${keychain}"
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
    # 後始末は 1 つ失敗しても続ける（trap の中でも set -e が効くため、|| true を付ける）
    trap "security delete-keychain '${keychain}' 2>/dev/null || true; security delete-keychain '${work}/export.keychain-db' 2>/dev/null || true; rm -rf '${work}'" EXIT
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
    local sha1 identity
    AUTONOTE_SELFTEST_PASS="$("${OPENSSL}" rand -hex 16)"
    export AUTONOTE_SELFTEST_PASS
    # shellcheck disable=SC2046
    "${OPENSSL}" pkcs12 -export $(pkcs12_compat) -inkey "${work}/key.pem" -in "${work}/cert.pem" \
        -name "AutoNote Signing Selftest" -passout env:AUTONOTE_SELFTEST_PASS -out "${work}/id.p12"
    rm -f "${work}/key.pem"
    sha1="$(sha1_of_pem <"${work}/cert.pem")"
    echo "使い捨ての証明書: SHA-1 ${sha1}"
    identity="$(AUTONOTE_SIGNING_P12_BASE64="$(base64 -i "${work}/id.p12")" AUTONOTE_SIGNING_P12_PASSWORD="${AUTONOTE_SELFTEST_PASS}" \
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
    selftest_export_one "${work}"
    echo "selftest: 合格"
}

# export-to-1password の書き出し部分: identity が 2 つある一時キーチェーンから、指定の 1 つだけが p12 に入ること
selftest_export_one() {
    local work="$1" n
    local keychain="${work}/export.keychain-db"
    command -v swift >/dev/null || { echo "（swift が無いので書き出しの確認は省略）"; return 0; }
    for n in one two; do
        "${OPENSSL}" req -x509 -newkey rsa:2048 -days 1 -nodes -config "${work}/cert.cnf" -subj "/CN=AutoNote Export Selftest ${n}" \
            -keyout "${work}/${n}.key" -out "${work}/${n}.pem" 2>/dev/null
        # shellcheck disable=SC2046
        "${OPENSSL}" pkcs12 -export $(pkcs12_compat) -inkey "${work}/${n}.key" -in "${work}/${n}.pem" \
            -passout env:AUTONOTE_SELFTEST_PASS -out "${work}/${n}.p12"
        rm -f "${work}/${n}.key"
    done
    security create-keychain -p "${AUTONOTE_SELFTEST_PASS}" "${keychain}"
    security unlock-keychain -p "${AUTONOTE_SELFTEST_PASS}" "${keychain}"
    # -A: このテスト用の鍵だけは確認なしで書き出せるようにする（本物の鍵は codesign だけを許す）
    for n in one two; do
        security import "${work}/${n}.p12" -k "${keychain}" -f pkcs12 -P "${AUTONOTE_SELFTEST_PASS}" -A >/dev/null
    done
    local want got keys
    want="$(sha1_of_pem <"${work}/two.pem")"
    AUTONOTE_EXPORT_PASSWORD="${AUTONOTE_SELFTEST_PASS}" swift "${ROOT}/scripts/export-identity.swift" "${want}" \
        "${work}/out.p12" "${keychain}" || { security delete-keychain "${keychain}"; die "export-identity.swift が書き出せない"; }
    security delete-keychain "${keychain}"
    got="$(p12_pem "${work}/out.p12" AUTONOTE_SELFTEST_PASS -nokeys -clcerts | sha1_of_pem)"
    keys="$(p12_pem "${work}/out.p12" AUTONOTE_SELFTEST_PASS | grep -c 'BEGIN .*PRIVATE KEY')"
    [[ "${got}" == "${want}" && "${keys}" == 1 ]] || die "書き出した p12 が指定の 1 件だけになっていない（証明書 ${got}、鍵 ${keys} 個）"
    rm -f "${work}/out.p12"
    echo "export-identity.swift: 2 つのうち指定の 1 件（証明書と鍵 1 つ）だけを書き出した"
}

# 1Password アプリの連携の承認は親プロセスごとに要る。`op whoami` は承認ダイアログを出さないので使わず、ダイアログを出す
# `op vault list` で確かめる（承認されれば同じシェルの続く op はそのまま通る）。続けて OP_VAULT があるかを見る
require_op() {
    [[ -x "${OP}" ]] || die "1Password CLI（op）がありません"
    echo "1Password の承認ダイアログが出たら承認してください（約 60 秒で打ち切られます）" >&2
    local out
    if ! out="$("${OP}" vault list --format json 2>&1)"; then
        if grep -qiE "timeout|timed out" <<<"${out}"; then
            die "1Password の承認が時間内にありませんでした（authorization timeout）。ダイアログを承認して、もう一度実行してください"
        fi
        die "op で 1Password に接続できません: $(tail -n 1 <<<"${out}")（1Password アプリの 設定 → 開発者 → 「1Password CLI と連携」がオンか確かめてください）"
    fi
    local names
    names="$(python3 -I -c 'import json,sys; print("\n".join(v.get("name","") for v in json.load(sys.stdin)))' <<<"${out}" 2>/dev/null)"
    if ! grep -qxF -- "${OP_VAULT}" <<<"${names}"; then
        echo "保管庫「${OP_VAULT}」がありません。使える保管庫:" >&2
        sed 's/^/  - /' <<<"${names}" >&2
        die "OP_VAULT=<保管庫の名前> を付けて、もう一度実行してください"
    fi
}

# 同名の項目が保管庫にあるか（二重に作らないため）
op_item_exists() {
    "${OP}" item get "$1" --vault "${OP_VAULT}" --format json >/dev/null 2>&1
}

cmd_export_to_1password() {
    require_op
    gh auth status >/dev/null 2>&1 || die "gh がログインしていません"
    # 既に保存済みなら何も作らない（鍵を書き出す前に止める）。作り直すなら、古い項目を 1Password で消すか名前を変えてから
    local title
    for title in "${OP_ITEM_PREFIX} (p12)" "${OP_ITEM_PREFIX} (p12 password)"; do
        op_item_exists "${title}" && die "1Password の保管庫「${OP_VAULT}」に「${title}」が既にあります。二重に作らないので止めます（作り直すなら古い項目を消すか OP_ITEM_PREFIX を変える）"
    done
    security find-certificate -c "${AUTONOTE_CERT_NAME}" -Z "${LOGIN_KEYCHAIN}" 2>/dev/null | grep -qi "SHA-1 hash: ${AUTONOTE_CERT_SHA1}" \
        || die "login キーチェーンに SHA-1 ${AUTONOTE_CERT_SHA1} の「${AUTONOTE_CERT_NAME}」がありません"
    local work; work="$(private_dir)"
    # shellcheck disable=SC2064
    trap "rm -rf '${work}'" EXIT
    AUTONOTE_EXPORT_PASSWORD="$("${OPENSSL}" rand -hex 24)"
    AUTONOTE_P12_PASSWORD="$("${OPENSSL}" rand -base64 30 | tr -d '/+=' | head -c 32)"
    export AUTONOTE_EXPORT_PASSWORD AUTONOTE_P12_PASSWORD
    echo "login キーチェーンから「${AUTONOTE_CERT_NAME}」だけを書き出します（macOS がキーチェーンのパスワードを 1 回たずねます）"
    swift "${ROOT}/scripts/export-identity.swift" "${AUTONOTE_CERT_SHA1}" "${work}/export.p12" "${LOGIN_KEYCHAIN}" \
        || die "書き出せませんでした（swift が要ります。キーチェーンの確認を拒否した場合も失敗します）"
    repack_p12 "${work}/export.p12" AUTONOTE_EXPORT_PASSWORD "${work}/autonote-signing.p12" AUTONOTE_P12_PASSWORD "${AUTONOTE_CERT_NAME}"
    rm -f "${work}/export.p12"
    [[ "$(p12_pem "${work}/autonote-signing.p12" AUTONOTE_P12_PASSWORD -nokeys -clcerts | sha1_of_pem)" == "${AUTONOTE_CERT_SHA1}" ]] \
        || die "作った p12 の証明書が SHA-1 ${AUTONOTE_CERT_SHA1} ではありません"
    local p12_pass="${AUTONOTE_P12_PASSWORD}"
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
    AUTONOTE_P12_PASSWORD="$("${OP}" read "op://${OP_VAULT}/${OP_ITEM_PREFIX} (p12 password)/password")"
    export AUTONOTE_P12_PASSWORD
    import_p12 "${work}/id.p12" AUTONOTE_P12_PASSWORD "${LOGIN_KEYCHAIN}"
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
