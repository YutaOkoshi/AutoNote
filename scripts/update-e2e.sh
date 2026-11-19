#!/usr/bin/env bash
# 自動アップデートの E2E。一時ディレクトリに置いたアプリの写しと、手元の偽の配布サーバー（python3 の http.server）で、
# 確認 → 取得 → 検証 → 入れ替え → 再起動と、拒否・延期・復旧を確かめる。/Applications のアプリと利用者のデータには触れない。
#
# 使い方: scripts/update-e2e.sh [<AutoNote.app>]   （既定は build/AutoNote.app。debug 構成で「AutoNote Dev」署名のもの）
#   各項目の結果を「PASS|FAIL|SKIP  <番号> <名前>[ — 理由]」の 1 行で出す（scripts/e2e-check.sh の項目 16 が読む）。
#   FAIL が 1 つでもあれば終了コード 1。詳細なログは E2E_UPDATE_KEEP=1 のとき一時ディレクトリに残す（パスを最後に出す）。
# 前提: 署名証明書「AutoNote Dev」がある（写しの版を書き換えて署名し直すため）、python3、GUI のログイン中。
#
# E2E_UPDATE_IDENTITY=untrusted: 「AutoNote Dev」の代わりに、その場で作った使い捨ての自己署名証明書（どこにも信頼設定が
#   無い）でアプリの写しと各版を署名し、署名し終えたら証明書のキーチェーンを消してから試す。利用者の Mac と同じく、
#   署名者の証明書が信頼されていない（キーチェーンにも無い）状態で、アプリと同じ署名の検査（`autonote dev update --check`
#   が使う UpdateChecker / SecStaticCodeCheckValidity）と、入れ替えの補助が使う `codesign --verify -R=` が通ることを見る。
#   項目の番号は 16u.N。アプリ（GUI）は起動しない: 署名が変わったアプリはマイクの許可を改めて求め、その答えが
#   この Mac の AutoNote の許可（TCC の項目は bundle identifier ごとに 1 つ）を上書きしてしまうため。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=config.sh
source "${ROOT}/scripts/config.sh"
SRC_APP="${1:-${ROOT}/build/AutoNote.app}"
CERT="${AUTONOTE_CERT_NAME}"
BUNDLE_ID="${AUTONOTE_BUNDLE_ID}"
PB=/usr/libexec/PlistBuddy
UNTRUSTED=0; N=16
[[ "${E2E_UPDATE_IDENTITY:-}" == untrusted ]] && { UNTRUSTED=1; N=16u; }
KEYCHAIN=""

T="$(mktemp -d /tmp/an-upd.XXXXXX)"   # 短いパス（ソケットのパス上限）
INST="${T}/inst/AutoNote.app"
SRV="${T}/srv"
SERVER_PID=""
N_FAIL=0

result() { printf '%s  %s%s\n' "$1" "$2" "${3:+ — $3}"; [[ "$1" == FAIL ]] && N_FAIL=$((N_FAIL + 1)); return 0; }

# この E2E が起動したプロセス（パスが ${T}/ の下のもの）だけを止める。他の worktree や /Applications のアプリには触れない
stop_ours() {
    local pids
    pids="$(/bin/ps -axo pid=,command= | /usr/bin/grep -F -- "${T}/inst/" | /usr/bin/grep -v -e grep -e update-e2e | awk '{print $1}')"
    [[ -n "${pids}" ]] && kill ${pids} 2>/dev/null
    local i
    for i in $(seq 1 50); do
        /bin/ps -axo command= | /usr/bin/grep -F -- "${T}/inst/AutoNote.app/Contents/MacOS/AutoNoteApp" | /usr/bin/grep -vq grep || return 0
        sleep 0.1
    done
}
cleanup() {
    stop_ours
    [[ -n "${KEYCHAIN}" ]] && "${ROOT}/scripts/signing.sh" delete-keychain "${KEYCHAIN}" >/dev/null 2>&1
    [[ -n "${SERVER_PID}" ]] && kill "${SERVER_PID}" 2>/dev/null
    if [[ "${E2E_UPDATE_KEEP:-0}" == 1 ]]; then echo "ログ: ${T}"; else rm -rf "${T}"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

[[ -x "${SRC_APP}/Contents/MacOS/AutoNoteApp" ]] || { result SKIP "${N}" "アプリが無い: ${SRC_APP}"; exit 0; }
if [[ "${UNTRUSTED}" -eq 0 ]]; then
    security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${CERT}\"" || { result SKIP "${N}" "署名証明書「${CERT}」が無い"; exit 0; }
fi
command -v python3 >/dev/null || { result SKIP "${N}" "python3 が無い"; exit 0; }

# 使い捨ての証明書（信頼設定なし）で、アプリの写しを中から外へ署名し直す。以後の写しと各版はこれが元
if [[ "${UNTRUSTED}" -eq 1 ]]; then
    O="$(command -v /opt/homebrew/bin/openssl || command -v openssl)"
    mkdir -p "${T}/cert" && chmod 700 "${T}/cert"
    printf '[ req ]\ndistinguished_name = dn\nx509_extensions = e\nprompt = no\n[ dn ]\nCN = AutoNote E2E Untrusted\n[ e ]\nbasicConstraints = critical, CA:false\nkeyUsage = critical, digitalSignature\nextendedKeyUsage = critical, codeSigning\nsubjectKeyIdentifier = hash\n' >"${T}/cert/c.cnf"
    "${O}" req -x509 -newkey rsa:2048 -days 1 -nodes -config "${T}/cert/c.cnf" -keyout "${T}/cert/k.pem" -out "${T}/cert/c.pem" 2>/dev/null
    export AUTONOTE_E2E_P12_PASS; AUTONOTE_E2E_P12_PASS="$("${O}" rand -hex 16)"
    compat=(); "${O}" version | grep -q '^LibreSSL' || compat=(-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1)
    "${O}" pkcs12 -export "${compat[@]}" -inkey "${T}/cert/k.pem" -in "${T}/cert/c.pem" -passout env:AUTONOTE_E2E_P12_PASS -out "${T}/cert/id.p12"
    rm -f "${T}/cert/k.pem"
    if security verify-cert -c "${T}/cert/c.pem" -p codeSign >/dev/null 2>&1; then result FAIL "${N}" "使い捨ての証明書が信頼されている"; exit 1; fi
    sha1="$("${O}" x509 -in "${T}/cert/c.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr '[:upper:]' '[:lower:]')"
    KEYCHAIN="${T}/cert/e2e.keychain-db"
    CERT="$(AUTONOTE_SIGNING_P12_BASE64="$(base64 -i "${T}/cert/id.p12")" AUTONOTE_SIGNING_P12_PASSWORD="${AUTONOTE_E2E_P12_PASS}" \
        AUTONOTE_EXPECT_CERT_SHA1="${sha1}" "${ROOT}/scripts/signing.sh" import-ci "${KEYCHAIN}" 2>"${T}/cert/import.log")" \
        || { result FAIL "${N}" "使い捨ての証明書を取り込めない: $(tail -n 1 "${T}/cert/import.log")"; exit 1; }
    mkdir -p "${T}/base"
    ditto "${SRC_APP}" "${T}/base/AutoNote.app"
    AUTONOTE_CODESIGN_KEYCHAIN="${KEYCHAIN}" "${ROOT}/scripts/sign-app.sh" "${T}/base/AutoNote.app" "${CERT}" >"${T}/cert/sign.log" 2>&1 \
        || { result FAIL "${N}" "使い捨ての証明書で署名できない: $(tail -n 1 "${T}/cert/sign.log")"; exit 1; }
    SRC_APP="${T}/base/AutoNote.app"
    # アプリの起動時の検査（SecCodeCopySelf → SecCodeCheckValidity → designated requirement）と同じ手順の小さなプログラム
    cat >"${T}/cert/probe.swift" <<'SWIFT'
import Foundation
import Security
var me: SecCode?
guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { print("copy-self-failed"); exit(1) }
let v = SecCodeCheckValidity(me, [], nil)
guard v == errSecSuccess else { print("invalid \(v)"); exit(1) }
var r: SecRequirement?
guard SecCodeCopyDesignatedRequirement(unsafeBitCast(me, to: SecStaticCode.self), [], &r) == errSecSuccess, let r else { exit(1) }
var t: CFString?
SecRequirementCopyString(r, [], &t)
print((t as String?) ?? "")
SWIFT
    swiftc -o "${T}/cert/probe" "${T}/cert/probe.swift" 2>"${T}/cert/probe.log" \
        && codesign --force --sign "${CERT}" --keychain "${KEYCHAIN}" --timestamp=none "${T}/cert/probe" 2>>"${T}/cert/probe.log" \
        || { result FAIL "${N}" "検査用のプログラムを作れない: $(tail -n 1 "${T}/cert/probe.log")"; exit 1; }
fi
CLI="${SRC_APP}/Contents/MacOS/autonote"

CUR="$("${PB}" -c 'Print :CFBundleShortVersionString' "${SRC_APP}/Contents/Info.plist")"
DR_BEFORE="$(codesign -d -r- "${SRC_APP}" 2>&1 | sed -n 's/^designated => //p')"
mkdir -p "${SRV}" "${T}/variants"

# make_variant <名前> <版> <署名 identity> [LSMinimumSystemVersion]: 写しの版を書き換えて署名し直し、zip にする
make_variant() {
    local name="$1" version="$2" identity="$3" minos="${4:-}"
    local app="${T}/variants/${name}/AutoNote.app"
    mkdir -p "${T}/variants/${name}"
    ditto "${SRC_APP}" "${app}"
    "${PB}" -c "Set :CFBundleShortVersionString ${version}" "${app}/Contents/Info.plist"
    [[ -n "${minos}" ]] && "${PB}" -c "Set :LSMinimumSystemVersion ${minos}" "${app}/Contents/Info.plist"
    local kc=(); [[ -n "${KEYCHAIN}" && "${identity}" != - ]] && kc=(--keychain "${KEYCHAIN}")
    codesign --force --sign "${identity}" ${kc[@]+"${kc[@]}"} --identifier "${BUNDLE_ID}" --timestamp=none "${app}" >/dev/null 2>&1 || return 1
    ditto -c -k --keepParent "${app}" "${SRV}/${name}.zip"
}
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# feed <版> <zip の名前> [digest]: 偽の releases/latest を書く
feed() {
    local version="$1" zip="$2" digest="${3:-$(sha "${SRV}/$2.zip")}"
    cat >"${SRV}/latest.json.tmp" <<JSON
{"tag_name": "v${version}", "draft": false, "prerelease": false,
 "assets": [{"name": "AutoNote-${version}-macos-universal.zip",
             "browser_download_url": "http://127.0.0.1:${PORT}/${zip}.zip", "digest": "sha256:${digest}"}]}
JSON
    mv "${SRV}/latest.json.tmp" "${SRV}/latest.json"
}

make_variant good 9.9.9 "${CERT}" || { result FAIL "${N}" "写しの署名に失敗（good）"; exit 1; }
make_variant adhoc 9.9.7 - || { result FAIL "${N}" "写しの署名に失敗（adhoc）"; exit 1; }
make_variant broken 9.9.8 "${CERT}" 99.0 || { result FAIL "${N}" "写しの署名に失敗（broken）"; exit 1; }
# 署名し終えたので、使い捨ての証明書はこの Mac のどこにも残さない（利用者の Mac と同じ: 署名者の証明書を持っていない）
if [[ -n "${KEYCHAIN}" ]]; then
    "${ROOT}/scripts/signing.sh" delete-keychain "${KEYCHAIN}" >/dev/null 2>&1
    KEYCHAIN=""
    security find-identity -p codesigning 2>/dev/null | grep -qi "${CERT}" && { result FAIL "${N}" "使い捨ての証明書が残っている"; exit 1; }
fi
# 悪性の zip（レビュー M1）: 正しく署名した写しの zip に、展開先の外へ書く項目／外を指すシンボリックリンクを足す
mkdir -p "${T}/tools"
cat >"${T}/tools/evil.py" <<'PY'
import shutil, stat, sys, zipfile
src, out, kind = sys.argv[1], sys.argv[2], sys.argv[3]
shutil.copy(src, out)
with zipfile.ZipFile(out, "a") as z:
    def add(name, data, mode):
        i = zipfile.ZipInfo(name); i.create_system = 3; i.external_attr = mode << 16
        z.writestr(i, data)
    if kind == "dotdot":
        add("../../../escape-e2e.txt", b"escaped", stat.S_IFREG | 0o644)
    else:
        add("AutoNote.app/Contents/out", sys.argv[4].encode(), stat.S_IFLNK | 0o755)
PY
python3 -I "${T}/tools/evil.py" "${SRV}/good.zip" "${SRV}/evil-dotdot.zip" dotdot
python3 -I "${T}/tools/evil.py" "${SRV}/good.zip" "${SRV}/evil-link.zip" link "${T}/outside"
mkdir -p "${T}/outside"

PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -I -m http.server "${PORT}" --bind 127.0.0.1 --directory "${SRV}" >"${T}/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:${PORT}/" && break; sleep 0.1; done

# 入れ替え前のアプリを置き直し、使い捨てのデータ領域で起動する
DATA=""
launch() {
    stop_ours
    rm -rf "${T}/inst" "${T}/inst"/.AutoNote-update.app
    mkdir -p "${T}/inst"
    ditto "${SRC_APP}" "${INST}"
    DATA="${T}/d$1"
    mkdir -p "${DATA}"
    printf '{"launch_at_login": false, "first_run_completed": true, "claude_path": "/nonexistent-autonote-e2e/claude"}\n' >"${DATA}/settings.json"
    AUTONOTE_DATA_DIR="${DATA}" AUTONOTE_UPDATE_FEED_URL="http://127.0.0.1:${PORT}/latest.json" \
        "${INST}/Contents/MacOS/AutoNoteApp" >"${DATA}/app.log" 2>&1 &
    APP_PID=$!
}
app_pids() { /bin/ps -axo pid=,command= | /usr/bin/grep -F -- "${INST}/Contents/MacOS/AutoNoteApp" | /usr/bin/grep -v grep | awk '{print $1}'; }
status_json() { AUTONOTE_DATA_DIR="${DATA}" "${CLI}" dev update --status 2>/dev/null; }
field() { python3 -I -c 'import json,sys
try: d=json.loads(sys.stdin.read() or "{}")
except Exception: d={}
for k in sys.argv[1].split("."): d=d.get(k) if isinstance(d,dict) else None
print("" if d is None else d)' "$1"; }
# wait_state <状態> <秒>: update.status の state が <状態> になるまで待つ。最後の JSON を LAST に残す
LAST=""
wait_state() {
    local want="$1" secs="$2" i
    for i in $(seq 1 $((secs * 2))); do
        LAST="$(status_json)"
        [[ "$(field state <<<"${LAST}")" == "${want}" ]] && return 0
        sleep 0.5
    done
    return 1
}
installed_version() { "${PB}" -c 'Print :CFBundleShortVersionString' "${INST}/Contents/Info.plist" 2>/dev/null; }

# ---- 信頼の無い証明書: アプリを起動せず、CLI で同じ検査を通す（上の E2E_UPDATE_IDENTITY=untrusted の説明）
if [[ "${UNTRUSTED}" -eq 1 ]]; then
    DATA="${T}/du"; mkdir -p "${DATA}"
    check_cli() { AUTONOTE_DATA_DIR="${DATA}" "${CLI}" dev update --check --feed "http://127.0.0.1:${PORT}/latest.json" --app "${SRC_APP}" 2>/dev/null | tail -n 1; }
    expect_refused() {   # <番号と名前> <message に含む語> <版> <zip> [digest]
        feed "$3" "$4" ${5:+"$5"}
        LAST="$(check_cli)"
        if [[ "$(field state <<<"${LAST}")" == refused && "$(field message <<<"${LAST}")" == *"$2"* ]]; then
            result PASS "$1" "$(field message <<<"${LAST}")"
        else
            result FAIL "$1" "${LAST:-出力なし}"
        fi
    }
    expect_refused "${N}.1 SHA-256 違いの zip を拒否" SHA-256 9.9.9 good "$(printf '0%.0s' $(seq 1 64))"
    expect_refused "${N}.2 署名が違う zip を拒否" 署名 9.9.7 adhoc
    expect_refused "${N}.7 展開先の外へ書く項目（../）を含む zip を拒否" 想定外の項目 9.9.6 evil-dotdot
    expect_refused "${N}.8 アプリの外を指すシンボリックリンクを含む zip を拒否" 想定外の項目 9.9.5 evil-link
    result SKIP "${N}.3 起動できない版は元に戻して再起動" "アプリを起動しない（マイクの許可を上書きしないため。16.3 で見る）"
    result SKIP "${N}.4 録音中は入れ替えを延期" "アプリを起動しない（16.4 で見る）"
    # 16u.5: 正しく署名した版は、信頼の無い証明書でもアプリと同じ検査（UpdateChecker.prepare）に通る
    feed 9.9.9 good
    LAST="$(check_cli)"
    if [[ "$(field state <<<"${LAST}")" == verified && "$(field latest <<<"${LAST}")" == 9.9.9 ]]; then
        result PASS "${N}.5 信頼の無い証明書の版がアプリと同じ検査に通る" "$(field message <<<"${LAST}")"
    else
        result FAIL "${N}.5 信頼の無い証明書の版がアプリと同じ検査に通る" "${LAST:-出力なし}"
    fi
    # 16u.6: 入れ替えの補助と同じ検査（codesign --verify --deep --strict -R=）と、DR が元と同じこと
    good_app="${T}/variants/good/AutoNote.app"
    DR_GOOD="$(codesign -d -r- "${good_app}" 2>&1 | sed -n 's/^designated => //p')"
    if [[ -n "${DR_BEFORE}" && "${DR_GOOD}" == "${DR_BEFORE}" && "${DR_BEFORE}" == *"certificate leaf = H\"${sha1}\""* ]] \
        && codesign --verify --deep --strict "-R=${DR_BEFORE}" "${good_app}" >"${T}/verify.log" 2>&1; then
        result PASS "${N}.6 入れ替えの補助の検査（codesign -R=）が通り、DR が元と同じ" "${DR_GOOD}"
    else
        result FAIL "${N}.6 入れ替えの補助の検査（codesign -R=）が通り、DR が元と同じ" "前 ${DR_BEFORE} / 新 ${DR_GOOD} / $(tail -n 1 "${T}/verify.log")"
    fi
    # 16u.9: 起動中のアプリが自分の requirement を読む手順（SecCodeCopySelf → SecCodeCheckValidity）も通る
    probe_out="$("${T}/cert/probe" 2>&1)"
    if [[ "${probe_out}" == *"certificate leaf = H\"${sha1}\""* ]]; then
        result PASS "${N}.9 起動中のプロセスが自分の署名を確かめて requirement を読める" "${probe_out}"
    else
        result FAIL "${N}.9 起動中のプロセスが自分の署名を確かめて requirement を読める" "${probe_out:-出力なし}"
    fi
    exit $(( N_FAIL > 0 ? 1 : 0 ))
fi

# ---- 16.1 SHA-256 が合わない zip は入れ替えない
feed 9.9.9 good "$(printf '0%.0s' $(seq 1 64))"
launch 1
if wait_state failed 30 && [[ "$(field message <<<"${LAST}")" == *SHA-256* ]] && kill -0 "${APP_PID}" 2>/dev/null \
    && [[ "$(installed_version)" == "${CUR}" ]]; then
    result PASS "${N}.1 SHA-256 違いの zip を拒否" "$(field message <<<"${LAST}")"
else
    result FAIL "${N}.1 SHA-256 違いの zip を拒否" "状態 ${LAST:-なし}"
fi

# ---- 16.2 署名が違う（アドホック）zip は入れ替えない
feed 9.9.7 adhoc
launch 2
if wait_state failed 30 && [[ "$(field message <<<"${LAST}")" == *署名* ]] && kill -0 "${APP_PID}" 2>/dev/null \
    && [[ "$(installed_version)" == "${CUR}" ]]; then
    result PASS "${N}.2 署名が違う zip を拒否" "$(field message <<<"${LAST}")"
else
    result FAIL "${N}.2 署名が違う zip を拒否" "状態 ${LAST:-なし}"
fi

# ---- 16.7 / 16.8 展開先の外へ書く zip・外を指すシンボリックリンクを含む zip は、署名を見る前に拒否する
for case in "${N}.7 展開先の外へ書く項目（../）を含む zip を拒否|evil-dotdot|9.9.6" \
            "${N}.8 アプリの外を指すシンボリックリンクを含む zip を拒否|evil-link|9.9.5"; do
    IFS='|' read -r name zip version <<<"${case}"
    feed "${version}" "${zip}"
    launch "${version//./}"
    if wait_state failed 30 && [[ "$(field message <<<"${LAST}")" == *想定外* ]] && kill -0 "${APP_PID}" 2>/dev/null \
        && [[ "$(installed_version)" == "${CUR}" && -z "$(find "${T}" -name escape-e2e.txt 2>/dev/null)" ]] \
        && [[ -z "$(ls -A "${T}/outside")" && ! -e "${DATA}/updates/${version}" ]]; then
        result PASS "${name}" "$(field message <<<"${LAST}")"
    else
        result FAIL "${name}" "状態 ${LAST:-なし}、外に書かれた: $(find "${T}" -name escape-e2e.txt 2>/dev/null | head -n 1)"
    fi
done

# ---- 16.3 起動できない版（LSMinimumSystemVersion 99.0）への入れ替えは、元の版に戻して起動し直す
feed 9.9.8 broken
launch 3
first="${APP_PID}" ok=0
for _ in $(seq 1 120); do
    sleep 0.5
    kill -0 "${first}" 2>/dev/null && continue
    pids="$(app_pids)"
    if [[ -n "${pids}" ]] && [[ "$(field last_install.result <<<"$(status_json)")" == restored ]]; then ok=1; break; fi
done
LAST="$(status_json)"
if [[ "${ok}" -eq 1 && "$(installed_version)" == "${CUR}" && ! -e "${T}/inst/.AutoNote-update.app" ]] \
    && grep -q '"failed_version" : "9.9.8"' "${DATA}/updates/state.json" 2>/dev/null; then
    result PASS "${N}.3 起動できない版は元に戻して再起動" "$(field message <<<"${LAST}")"
else
    result FAIL "${N}.3 起動できない版は元に戻して再起動" "版 $(installed_version)、状態 ${LAST:-なし}、log: $(tail -n 3 "${DATA}/updates/install.log" 2>/dev/null | LC_ALL=C tr '\n' ' ')"
fi

# ---- 16.4 録音中は入れ替えを待ち、止めたあとに入れ替えて再起動する（許可が保たれる根拠: DR が同じ）
feed "${CUR}" good   # まずは「最新」
launch 4
wait_state up_to_date 30 || result FAIL "${N}.4 準備" "最初の確認が up_to_date にならない: ${LAST:-なし}"
first="${APP_PID}"
recording=0
if AUTONOTE_DATA_DIR="${DATA}" "${CLI}" start >"${T}/start.log" 2>&1; then recording=1; fi
feed 9.9.9 good
AUTONOTE_DATA_DIR="${DATA}" "${CLI}" dev update --now >"${T}/now.json" 2>&1
if [[ "${recording}" -eq 1 ]]; then
    sleep 12   # 再起動待ちのゲートは 10 秒ごとに見直す。録音中なので入れ替わらないこと
    LAST="$(status_json)"
    if [[ "$(field state <<<"${LAST}")" == ready_to_install && "$(field waiting <<<"${LAST}")" == 録音中です ]] \
        && kill -0 "${first}" 2>/dev/null && [[ "$(installed_version)" == "${CUR}" ]]; then
        result PASS "${N}.4 録音中は入れ替えを延期" "$(field message <<<"${LAST}")"
    else
        result FAIL "${N}.4 録音中は入れ替えを延期" "状態 ${LAST:-なし}"
    fi
    AUTONOTE_DATA_DIR="${DATA}" "${CLI}" stop >/dev/null 2>&1
else
    result SKIP "${N}.4 録音中は入れ替えを延期" "autonote start が失敗（マイク許可が無い環境か）: $(tail -n 1 "${T}/start.log")"
fi
ok=0
for _ in $(seq 1 240); do
    sleep 0.5
    kill -0 "${first}" 2>/dev/null && continue
    [[ -n "$(app_pids)" && "$(field last_install.result <<<"$(status_json)")" == installed ]] && { ok=1; break; }
done
# 補助は新しい版の起動を確かめてから退避を消して終わる（起動確認に数秒）
for _ in $(seq 1 40); do grep -q '完了' "${DATA}/updates/install.log" 2>/dev/null && break; sleep 0.5; done
LAST="$(status_json)"
DR_AFTER="$(codesign -d -r- "${INST}" 2>&1 | sed -n 's/^designated => //p')"
if [[ "${ok}" -eq 1 && "$(installed_version)" == 9.9.9 && "$(field current_version <<<"${LAST}")" == 9.9.9 ]] \
    && codesign --verify --strict "${INST}" 2>/dev/null && [[ ! -e "${T}/inst/.AutoNote-update.app" ]]; then
    result PASS "${N}.5 新しい版の検出 → 取得 → 検証 → 入れ替え → 再起動" "${CUR} → $(installed_version)"
else
    result FAIL "${N}.5 新しい版の検出 → 取得 → 検証 → 入れ替え → 再起動" "版 $(installed_version)、状態 ${LAST:-なし}、log: $(tail -n 3 "${DATA}/updates/install.log" 2>/dev/null | LC_ALL=C tr '\n' ' ')"
fi
if [[ "${ok}" -eq 1 && -n "${DR_BEFORE}" && "${DR_AFTER}" == "${DR_BEFORE}" ]]; then
    result PASS "${N}.6 入れ替え後の designated requirement が入れ替え前と同じ" "${DR_AFTER}"
else
    result FAIL "${N}.6 入れ替え後の designated requirement が入れ替え前と同じ" "前 ${DR_BEFORE} / 後 ${DR_AFTER}"
fi

[[ "${N_FAIL}" -eq 0 ]]
