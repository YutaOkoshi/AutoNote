#!/usr/bin/env bash
# 自動アップデートの E2E。一時ディレクトリに置いたアプリの写しと、手元の偽の配布サーバー（python3 の http.server）で、
# 確認 → 取得 → 検証 → 入れ替え → 再起動と、拒否・延期・復旧を確かめる。/Applications のアプリと利用者のデータには触れない。
#
# 使い方: scripts/update-e2e.sh [<AutoNote.app>]   （既定は build/AutoNote.app。debug 構成で「AutoNote Dev」署名のもの）
#   各項目の結果を「PASS|FAIL|SKIP  <番号> <名前>[ — 理由]」の 1 行で出す（scripts/e2e-check.sh の項目 15 が読む）。
#   FAIL が 1 つでもあれば終了コード 1。詳細なログは E2E_UPDATE_KEEP=1 のとき一時ディレクトリに残す（パスを最後に出す）。
# 前提: 署名証明書「AutoNote Dev」がある（写しの版を書き換えて署名し直すため）、python3、GUI のログイン中。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=config.sh
source "${ROOT}/scripts/config.sh"
SRC_APP="${1:-${ROOT}/build/AutoNote.app}"
CERT="${AUTONOTE_CERT_NAME}"
BUNDLE_ID="${AUTONOTE_BUNDLE_ID}"
CLI="${SRC_APP}/Contents/MacOS/autonote"
PB=/usr/libexec/PlistBuddy

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
    [[ -n "${SERVER_PID}" ]] && kill "${SERVER_PID}" 2>/dev/null
    if [[ "${E2E_UPDATE_KEEP:-0}" == 1 ]]; then echo "ログ: ${T}"; else rm -rf "${T}"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

[[ -x "${SRC_APP}/Contents/MacOS/AutoNoteApp" ]] || { result SKIP "15" "アプリが無い: ${SRC_APP}"; exit 0; }
security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${CERT}\"" || { result SKIP "15" "署名証明書「${CERT}」が無い"; exit 0; }
command -v python3 >/dev/null || { result SKIP "15" "python3 が無い"; exit 0; }

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
    codesign --force --sign "${identity}" --identifier "${BUNDLE_ID}" --timestamp=none "${app}" >/dev/null 2>&1 || return 1
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

make_variant good 9.9.9 "${CERT}" || { result FAIL "15" "写しの署名に失敗（good）"; exit 1; }
make_variant adhoc 9.9.7 - || { result FAIL "15" "写しの署名に失敗（adhoc）"; exit 1; }
make_variant broken 9.9.8 "${CERT}" 99.0 || { result FAIL "15" "写しの署名に失敗（broken）"; exit 1; }

PORT="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -I -m http.server "${PORT}" --bind 127.0.0.1 --directory "${SRV}" >"${T}/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:${PORT}/" && break; sleep 0.1; done

# 入れ替え前のアプリを置き直し、使い捨てのデータ領域で起動する
DATA=""
launch() {
    stop_ours
    rm -rf "${T}/inst" "${T}/inst"/.AutoNote-update-backup.app
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

# ---- 15.1 SHA-256 が合わない zip は入れ替えない
feed 9.9.9 good "$(printf '0%.0s' $(seq 1 64))"
launch 1
if wait_state failed 30 && [[ "$(field message <<<"${LAST}")" == *SHA-256* ]] && kill -0 "${APP_PID}" 2>/dev/null \
    && [[ "$(installed_version)" == "${CUR}" ]]; then
    result PASS "15.1 SHA-256 違いの zip を拒否" "$(field message <<<"${LAST}")"
else
    result FAIL "15.1 SHA-256 違いの zip を拒否" "状態 ${LAST:-なし}"
fi

# ---- 15.2 署名が違う（アドホック）zip は入れ替えない
feed 9.9.7 adhoc
launch 2
if wait_state failed 30 && [[ "$(field message <<<"${LAST}")" == *署名* ]] && kill -0 "${APP_PID}" 2>/dev/null \
    && [[ "$(installed_version)" == "${CUR}" ]]; then
    result PASS "15.2 署名が違う zip を拒否" "$(field message <<<"${LAST}")"
else
    result FAIL "15.2 署名が違う zip を拒否" "状態 ${LAST:-なし}"
fi

# ---- 15.3 起動できない版（LSMinimumSystemVersion 99.0）への入れ替えは、元の版に戻して起動し直す
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
if [[ "${ok}" -eq 1 && "$(installed_version)" == "${CUR}" && ! -e "${T}/inst/.AutoNote-update-backup.app" ]] \
    && grep -q '"failed_version" : "9.9.8"' "${DATA}/updates/state.json" 2>/dev/null; then
    result PASS "15.3 起動できない版は元に戻して再起動" "$(field message <<<"${LAST}")"
else
    result FAIL "15.3 起動できない版は元に戻して再起動" "版 $(installed_version)、状態 ${LAST:-なし}、log: $(tail -n 3 "${DATA}/updates/install.log" 2>/dev/null | LC_ALL=C tr '\n' ' ')"
fi

# ---- 15.4 録音中は入れ替えを待ち、止めたあとに入れ替えて再起動する（許可が保たれる根拠: DR が同じ）
feed "${CUR}" good   # まずは「最新」
launch 4
wait_state up_to_date 30 || result FAIL "15.4 準備" "最初の確認が up_to_date にならない: ${LAST:-なし}"
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
        result PASS "15.4 録音中は入れ替えを延期" "$(field message <<<"${LAST}")"
    else
        result FAIL "15.4 録音中は入れ替えを延期" "状態 ${LAST:-なし}"
    fi
    AUTONOTE_DATA_DIR="${DATA}" "${CLI}" stop >/dev/null 2>&1
else
    result SKIP "15.4 録音中は入れ替えを延期" "autonote start が失敗（マイク許可が無い環境か）: $(tail -n 1 "${T}/start.log")"
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
    && codesign --verify --strict "${INST}" 2>/dev/null && [[ ! -e "${T}/inst/.AutoNote-update-backup.app" ]]; then
    result PASS "15.5 新しい版の検出 → 取得 → 検証 → 入れ替え → 再起動" "${CUR} → $(installed_version)"
else
    result FAIL "15.5 新しい版の検出 → 取得 → 検証 → 入れ替え → 再起動" "版 $(installed_version)、状態 ${LAST:-なし}、log: $(tail -n 3 "${DATA}/updates/install.log" 2>/dev/null | LC_ALL=C tr '\n' ' ')"
fi
if [[ "${ok}" -eq 1 && -n "${DR_BEFORE}" && "${DR_AFTER}" == "${DR_BEFORE}" ]]; then
    result PASS "15.6 入れ替え後の designated requirement が入れ替え前と同じ" "${DR_AFTER}"
else
    result FAIL "15.6 入れ替え後の designated requirement が入れ替え前と同じ" "前 ${DR_BEFORE} / 後 ${DR_AFTER}"
fi

[[ "${N_FAIL}" -eq 0 ]]
