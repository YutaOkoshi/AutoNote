#!/usr/bin/env bash
# AutoNote の E2E 動作確認。リポジトリの成果物が「実際に動く」ことを人の手なしで確かめる。
#
# 使い方: scripts/e2e-check.sh [--quick] [--verbose]
#   --quick     時間のかかる項目（swift test / build-app / 04.3・04.4・08.1・08.2 の whisper）を飛ばす（SKIP と表示）
#   --verbose   各コマンドの出力をそのまま見せる（既定は FAIL のときだけ末尾 20 行）
# 環境変数（FAIL 検出の確認用。副作用なしで期待値だけを変える）:
#   E2E_EXPECT_VERSION   autonote --version の期待値（既定: Sources/AutoNoteCore/AutoNoteVersion.swift の値）
#   E2E_EXPECT_STATUS_ITEM_ID   項目 7b がメニューバー項目の AXIdentifier に期待する値（既定: autonote-status-item）
#   AUTONOTE_CLI         項目 01.x が使う autonote の場所（既定: .build/debug/autonote）
#   E2E_MENUBAR_INDEX    項目 7b・07.3・06.7 で見る menu bar の番号（既定: 2 = ステータス項目のメニューバー）
#   E2E_EXPECT_RECORDER_STATE   項目 06.3 が status --json の recorder.state に期待する値（既定: idle）
#   E2E_EXPECT_AUTOMATION_OUT   項目 06.5 が auto-out.txt に期待する 1 行（既定: minutes_generated <会議ID>）
# アプリを起動する項目は、必ず使い捨てのデータ領域（/tmp/an-e2e.XXXXXX。ソケットのパスを短く保つ）で動かし、利用者の実データには触らない。
# メニューバーや GUI を触る項目（7b・07.3・06.7）は、項目 7 が自分で起動したアプリだけを pid で指す（下の app_ax）。
# 同じ名前のインストール済みのアプリ（/Applications/AutoNote.app）が動いていても、そちらは読まない・開かない・押さない・止めない。
#
# 各項目は PASS / FAIL / SKIP の 1 行を出す。最後に集計し、FAIL が 1 つでもあれば終了コード 1。
# 機材・許可ダイアログ・ネットワーク・GUI に依存する項目は、条件がそろわなければ SKIP（失敗にしない）。
#
# ★ 新しい成果物（スクリプト、実行ターゲット、ビルド手順）を足したら、ここに確認項目を足す:
#   1. check_xxx 関数を書く（中で pass / fail / skip のどれかを必ず 1 回呼ぶ）
#   2. 末尾の CHECKS 配列に関数名を足す
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}" || exit 2

QUICK=0
VERBOSE=0
for arg in "$@"; do
    case "${arg}" in
        --quick) QUICK=1 ;;
        --verbose) VERBOSE=1 ;;
        -h|--help) sed -n "2,21p" "$0"; exit 0 ;;
        *) echo "不明な引数: ${arg}（使えるのは --quick と --verbose）" >&2; exit 2 ;;
    esac
done

APP="${ROOT}/build/AutoNote.app"
E2E_MEETING_ID="20261024-1400-a1b2"
E2E_FAILED_MEETING_ID="20261025-0930-c3d4"   # 07.4 の失敗ジョブ（Tests/Fixtures/queue）
# shellcheck source=config.sh
[[ -f "${ROOT}/scripts/config.sh" ]] && source "${ROOT}/scripts/config.sh"   # 無ければ 06.1 が FAIL する
CERT_NAME="${AUTONOTE_CERT_NAME:-}"
BUNDLE_ID="${AUTONOTE_BUNDLE_ID:-}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/autonote-e2e.XXXXXX")"
DATA="$(mktemp -d /tmp/an-e2e.XXXXXX)"   # AUTONOTE_DATA_DIR。unix ソケットのパス上限（約 104 バイト）に収まる短さにする
APP_PID=""
APP_MENU_OPENED=0   # 07.3 が自分のアプリのメニューを開いたら 1。閉じたのを確かめたら 0
cleanup() {
    # どの経路（PASS / SKIP / FAIL / 中断）でも、開いたメニューを閉じ、起動したアプリを必ず止める
    if [[ -n "${APP_PID}" ]]; then
        [[ "${APP_MENU_OPENED}" -eq 1 ]] && close_app_menu
        kill "${APP_PID}" 2>/dev/null; wait "${APP_PID}" 2>/dev/null
    fi
    rm -rf "${WORK}" "${DATA}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

N_PASS=0; N_FAIL=0; N_SKIP=0
CURRENT=""   # 実行中の項目名（pass/fail/skip が表示に使う）
LAST_LOG=""  # 直近の run の出力ファイル（fail のとき末尾を見せる）

pass() { N_PASS=$((N_PASS + 1)); printf 'PASS  %s%s\n' "${CURRENT}" "${1:+ — $1}"; }
skip() { N_SKIP=$((N_SKIP + 1)); printf 'SKIP  %s — %s\n' "${CURRENT}" "$1"; }
fail() {
    N_FAIL=$((N_FAIL + 1)); printf 'FAIL  %s — %s\n' "${CURRENT}" "$1"
    if [[ "${VERBOSE}" -eq 0 && -n "${LAST_LOG}" && -s "${LAST_LOG}" ]]; then
        tail -n 20 "${LAST_LOG}" | sed 's/^/      | /'
    fi
}

# run <コマンド...>: 出力を一時ファイル（LAST_LOG）に取り、終了コードを返す。--verbose なら出力も流す。
new_log() { LAST_LOG="${WORK}/log.$((N_PASS + N_FAIL + N_SKIP)).${RANDOM}"; : >"${LAST_LOG}"; }
exec_logged() {
    if [[ "${VERBOSE}" -eq 1 ]]; then
        "$@" 2>&1 | tee "${LAST_LOG}" | sed 's/^/      | /'
        return "${PIPESTATUS[0]}"
    fi
    "$@" >"${LAST_LOG}" 2>&1
}
run() { new_log; exec_logged "$@"; }

# run_timeout <秒> <コマンド...>: run と同じだが、時間切れなら kill して 124 を返す（coreutils の timeout に頼らない）。
run_timeout() {
    local secs="$1"; shift
    new_log   # バックグラウンドのサブシェルでは LAST_LOG を親に返せないので、ここで決める
    exec_logged "$@" &
    local pid=$! waited=0
    while kill -0 "${pid}" 2>/dev/null; do
        if (( waited >= secs * 10 )); then
            pkill -P "${pid}" 2>/dev/null; kill "${pid}" 2>/dev/null; wait "${pid}" 2>/dev/null
            echo "（${secs} 秒で打ち切り）" >>"${LAST_LOG}"
            return 124
        fi
        sleep 0.1; waited=$((waited + 1))
    done
    wait "${pid}"
}

# ---- 自分で起動したアプリだけを System Events で触るための補助 ----
# `tell process "AutoNoteApp"` は名前で引くので、同じ名前のプロセスが 2 つあるとどちらに当たるか決まらない。
# 2026-11-28 に、/Applications の AutoNote（常駐）のメニューを 07.3 が開いたままにし、そのアプリが終了の合図に
# 応じなくなった（メインスレッドがメニューバー項目のアクセシビリティ押下の中で止まっていた）。
# そのため必ず unix id（項目 7 の APP_PID）で引く。引けなければ別のプロセスには当てず、呼び手が SKIP にする。
# ★ プロセスやその要素への参照を AppleScript の変数に入れない（`set p to first process whose unix id is N` や
#   `set mb to menu bar item 1 of …` をしない）。System Events は返す参照を `application process "AutoNoteApp"` と
#   名前の形に直すので、変数を経由した次の命令は名前で引き直され、同じ名前の別のアプリに当たる（実測。pid で
#   引いたのに、先に起動していた同名のアプリの項目名が返った）。命令は下の tell の入れ子の中で、it（ステータス項目）
#   から相対で書く（title、selected、click it、menu 1 など）。値（文字列・真偽・名前のリスト）は変数に入れてよい。
# キー入力（key code 53 など）も送らない: 手前のアプリに届くので、利用者の作業や別のアプリのメニューに当たる。
AX_NO_PROCESS="E2E-NO-PROCESS-FOR-PID"
app_ax_script() {   # app_ax_script <tell の中身>: APP_PID のプロセスのステータス項目だけに向けた AppleScript を出す
    local idx="${E2E_MENUBAR_INDEX:-2}"
    cat <<OSA
with timeout of 8 seconds
tell application "System Events"
    if (count of (every process whose unix id is ${APP_PID})) is not 1 then error "${AX_NO_PROCESS} ${APP_PID}" number 9001
    tell (first process whose unix id is ${APP_PID})
        tell menu bar item 1 of menu bar ${idx}
$1
        end tell
    end tell
end tell
end timeout
OSA
}
# app_ax <秒> <tell の中身>: run_timeout と同じ（出力は LAST_LOG、時間切れは 124）。APP_PID が項目 7 で起動した
# build/AutoNote.app の AutoNoteApp でなければ何も送らず、AX_NO_PROCESS の行を LAST_LOG に書いて 1 を返す。
app_ax() {
    local secs="$1" body="$2"
    if [[ -z "${APP_PID}" ]] || ! kill -0 "${APP_PID}" 2>/dev/null \
        || [[ "$(ps -o comm= -p "${APP_PID}" 2>/dev/null)" != "${APP}/Contents/MacOS/AutoNoteApp" ]]; then
        new_log; echo "${AX_NO_PROCESS} ${APP_PID:-（なし）}: 項目 7 で起動した ${APP} のプロセスではない" >"${LAST_LOG}"
        return 1
    fi
    run_timeout "${secs}" osascript -e "$(app_ax_script "${body}")"
}
# app_ax の失敗（LAST_LOG）が「触れない環境」なら理由を出して 0、それ以外（menu bar が無い、時間切れなど）は 1。
# -1719 は「インデックスが正しくない」（menu bar が無い）にも使われるので、コード単体では判定せず文言で見る
ax_skip_reason() {
    if grep -q "${AX_NO_PROCESS}" "${LAST_LOG}"; then
        echo "pid ${APP_PID:-（なし）} を、項目 7 で起動したアプリとして特定できない（同じ名前の別のアプリには当てない）"
    elif grep -Eqi 'assistive|補助アクセス|-25211|-1743|Not authorized to send Apple events' "${LAST_LOG}"; then
        echo "アクセシビリティ（または Apple Events）の権限が無い: $(tail -n 1 "${LAST_LOG}")"
    else
        return 1
    fi
}
# 自分のアプリのメニューが開いていれば閉じる（AXCancel をそのメニューに送る。キー入力は使わない）。
# 開いているかはステータス項目の AXSelected で見る。閉じたのを確かめられたら 0。LAST_LOG は変えない
close_app_menu() {
    local log="${LAST_LOG}" n state="" rc=1
    for n in 1 2 3; do
        app_ax 10 '            if selected then perform action "AXCancel" of menu 1
            delay 0.3
            return selected' && state="$(cat "${LAST_LOG}")"
        if [[ "${state}" == "false" ]]; then APP_MENU_OPENED=0; rc=0; break; fi
        kill -0 "${APP_PID}" 2>/dev/null || break
    done
    LAST_LOG="${log}"
    return "${rc}"
}
# 見張り: 自分で起動したもの以外の AutoNoteApp（インストール済みのアプリなど）のうち、メニューが開いているものの pid を
# 空白区切りで出す（AXSelected を読むだけ。何も押さない）。07.3 が、メニューを開く前後で比べる
other_app_open_menus() {
    local pid out=""
    for pid in $(pgrep -x AutoNoteApp); do
        [[ "${pid}" == "${APP_PID}" ]] && continue
        [[ "$(osascript -e "with timeout of 5 seconds
tell application \"System Events\" to tell (first process whose unix id is ${pid}) to tell menu bar item 1 of menu bar ${E2E_MENUBAR_INDEX:-2} to return selected
end timeout" 2>/dev/null)" == "true" ]] && out+="${pid} "
    done
    printf '%s' "${out}"
}

have_cert() { security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${CERT_NAME}\""; }
have_gui() { [[ -z "${CI:-}" ]] && pgrep -x WindowServer >/dev/null 2>&1; }

# 共通の補助（すべての項目が使う）
AUTONOTE_CLI="${AUTONOTE_CLI:-${ROOT}/.build/debug/autonote}"   # 環境変数で差し替え可
AUTONOTE_CLI_BUILT=0
need_autonote_cli() {   # 0: 使える / 1: 無い（呼び手が skip）/ 2: ビルド失敗（呼び手が fail）。--quick でなければ最初の 1 回だけ swift build
    if [[ "${QUICK}" -eq 0 && "${AUTONOTE_CLI_BUILT}" -eq 0 ]]; then run swift build --product autonote || return 2; AUTONOTE_CLI_BUILT=1; fi
    [[ -x "${AUTONOTE_CLI}" ]] || return 1
}
cli_or_skip() {   # 項目の先頭で呼ぶ。使えなければ skip / fail を出して 1 を返す
    need_autonote_cli; case $? in 0) return 0 ;; 1) skip "autonote が無い（swift build で作る）" ;; *) fail "swift build --product autonote が失敗" ;; esac; return 1
}

# whisper.cpp の XCFramework（Package.swift の binaryTarget、tools/ は git 管理外）が無ければ先に作る。
# 項目 1 の swift test と AUTONOTE_CLI のビルドが新しい clone で失敗しないように。--quick はビルドしないので触らない
ensure_whisper_xcframework() {
    [[ "${QUICK}" -eq 1 ]] && return 0
    # 今の版（whisper.cpp と llama.cpp のコミット）で作成済みならスクリプトはすぐ終わる
    [[ -f "${ROOT}/tools/whisper.xcframework/Info.plist" ]] \
        || echo "tools/whisper.xcframework が無いので scripts/build-whisper-xcframework.sh で作る（数分かかる）"
    "${ROOT}/scripts/build-whisper-xcframework.sh" >"${WORK}/build-whisper-xcframework.log" 2>&1 && return 0
    echo "scripts/build-whisper-xcframework.sh が失敗（末尾 20 行）:" >&2
    tail -n 20 "${WORK}/build-whisper-xcframework.log" | sed 's/^/      | /' >&2
    return 1
}

# ---------------------------------------------------------------- 確認項目

check_swift_test() {
    CURRENT="1. swift test"
    [[ "${QUICK}" -eq 1 ]] && { skip "--quick"; return; }
    # 失敗したら --no-parallel で 1 回だけ再実行する（壁時計依存のテストが並列負荷で落ちるのを吸収する）
    if run .github/scripts/swift-test-retry.sh; then pass; else fail "swift test が失敗（直列の再実行でも）"; fi
}

check_build_app() {
    CURRENT="2. scripts/build-app.sh で build/AutoNote.app を作る"
    [[ "${QUICK}" -eq 1 ]] && { skip "--quick"; return; }
    # 証明書が無ければ build-app.sh が自動で作ってしまうので、ここでは走らせない
    have_cert || { skip "署名証明書「${CERT_NAME}」が無い（scripts/make-dev-cert.sh で作る）"; return; }
    if ! run scripts/build-app.sh; then fail "build-app.sh が 0 以外で終了"; return; fi
    if [[ -x "${APP}/Contents/MacOS/AutoNoteApp" && -x "${APP}/Contents/MacOS/autonote" ]]; then
        pass
    else
        LAST_LOG=""; fail "build/AutoNote.app/Contents/MacOS に実行ファイルが無い"
    fi
}

check_codesign_identity() {
    CURRENT="3. 署名の Identifier と Authority"
    have_cert || { skip "署名証明書「${CERT_NAME}」が無い"; return; }
    [[ -d "${APP}" ]] || { skip "build/AutoNote.app が無い（scripts/build-app.sh を先に）"; return; }
    if ! run codesign -dv --verbose=2 "${APP}"; then fail "codesign -dv が失敗"; return; fi
    local missing=()
    grep -qx "Identifier=${BUNDLE_ID}" "${LAST_LOG}" || missing+=("Identifier=${BUNDLE_ID}")
    grep -qx "Authority=${CERT_NAME}" "${LAST_LOG}" || missing+=("Authority=${CERT_NAME}")
    if [[ ${#missing[@]} -eq 0 ]]; then pass; else fail "見つからない: ${missing[*]}"; fi
}

check_codesign_verify() {
    CURRENT="4. codesign --verify --strict"
    [[ -d "${APP}" ]] || { skip "build/AutoNote.app が無い"; return; }
    if run codesign --verify --strict "${APP}"; then pass; else fail "署名の検証に失敗"; fi
}

check_identity_consistency() {
    CURRENT="06.1 Bundle ID の一本化"
    local cfg="${ROOT}/scripts/config.sh"
    [[ -f "${cfg}" ]] || { LAST_LOG=""; fail "scripts/config.sh が無い"; return; }
    local problems=() plist_id swift_id
    [[ -n "${AUTONOTE_BUNDLE_ID:-}" && -n "${AUTONOTE_CERT_NAME:-}" ]] || problems+=("config.sh が AUTONOTE_BUNDLE_ID / AUTONOTE_CERT_NAME を定義していない")
    plist_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${ROOT}/Resources/Info.plist" 2>/dev/null)"
    swift_id="$(sed -n 's/.*static let bundleID *\(: *String\)\{0,1\} *= *"\([^"]*\)".*/\2/p' "${ROOT}/Sources/AutoNoteCore/IPC/AppIdentity.swift" 2>/dev/null | head -1)"
    [[ "${plist_id}" == "${AUTONOTE_BUNDLE_ID}" ]] || problems+=("Info.plist の CFBundleIdentifier=${plist_id:-なし}")
    [[ "${swift_id}" == "${AUTONOTE_BUNDLE_ID}" ]] || problems+=("AppIdentity.bundleID=${swift_id:-なし}")
    local left
    left="$(grep -n -e 'com\.yutaokoshi\.autonote' -e '"AutoNote Dev"' "${ROOT}/scripts/build-app.sh" "${ROOT}/scripts/make-dev-cert.sh" | grep -v '^[^:]*:[0-9]*:#' || true)"
    [[ -z "${left}" ]] || problems+=("直書きが残っている: ${left//$'\n'/ ; }")
    LAST_LOG=""
    if [[ ${#problems[@]} -eq 0 ]]; then pass "${plist_id}"; else fail "${problems[*]}"; fi
}

check_info_plist() {
    CURRENT="5. Info.plist のキー"
    local plist="${APP}/Contents/Info.plist"
    [[ -f "${plist}" ]] || { skip "build/AutoNote.app が無い"; return; }
    local pb=/usr/libexec/PlistBuddy problems=() v
    for key in NSMicrophoneUsageDescription NSAudioCaptureUsageDescription; do
        v="$("${pb}" -c "Print :${key}" "${plist}" 2>/dev/null)" || { problems+=("${key} が無い"); continue; }
        [[ -n "${v}" ]] || problems+=("${key} が空")
    done
    v="$("${pb}" -c "Print :CFBundleIdentifier" "${plist}" 2>/dev/null)"
    [[ "${v}" == "${BUNDLE_ID}" ]] || problems+=("CFBundleIdentifier=${v:-なし}")
    v="$("${pb}" -c "Print :LSUIElement" "${plist}" 2>/dev/null)"
    [[ "${v}" == "true" ]] || problems+=("LSUIElement=${v:-なし}")
    LAST_LOG=""
    if [[ ${#problems[@]} -eq 0 ]]; then pass; else fail "${problems[*]}"; fi
}

check_bundle_version() {
    CURRENT="5b. Info.plist の CFBundleShortVersionString と AutoNoteVersion.current"
    local plist="${APP}/Contents/Info.plist"
    [[ -f "${plist}" ]] || { skip "build/AutoNote.app が無い"; return; }
    local plist_v swift_v
    plist_v="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${plist}" 2>/dev/null)"
    swift_v="$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' Sources/AutoNoteCore/AutoNoteVersion.swift)"
    LAST_LOG=""
    [[ -n "${swift_v}" ]] || { fail "AutoNoteVersion.swift から版を読めない"; return; }
    if [[ "${plist_v}" == "${swift_v}" ]]; then pass "${plist_v}"; else fail "Info.plist ${plist_v:-なし} ≠ AutoNoteVersion ${swift_v}"; fi
}

check_cli() {
    CURRENT="6. autonote --version と使い方"
    local cli="${APP}/Contents/MacOS/autonote"
    [[ -x "${cli}" ]] || { skip "build/AutoNote.app が無い"; return; }
    local expected
    expected="${E2E_EXPECT_VERSION:-$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' Sources/AutoNoteCore/AutoNoteVersion.swift)}"
    [[ -n "${expected}" ]] || { LAST_LOG=""; fail "AutoNoteVersion.swift から版を読めない"; return; }
    local out code
    out="$("${cli}" --version 2>"${WORK}/cli.err")"; code=$?
    if [[ ${code} -ne 0 || "${out}" != "${expected}" ]]; then
        LAST_LOG="${WORK}/cli.err"; fail "--version: exit ${code}, 出力「${out}」, 期待「${expected}」"; return
    fi
    out="$("${cli}" 2>"${WORK}/cli.err" >/dev/null)"; code=$?
    if [[ ${code} -ne 1 ]] || ! grep -q "usage:" "${WORK}/cli.err"; then
        LAST_LOG="${WORK}/cli.err"; fail "引数なし: exit ${code}（期待 1）、stderr に usage: があるか要確認"; return
    fi
    pass "版 ${expected}"
}

check_app_launch() {
    CURRENT="7. AutoNoteApp を起動してメニューバー項目を確認"
    local bin="${APP}/Contents/MacOS/AutoNoteApp"
    [[ -x "${bin}" ]] || { skip "build/AutoNote.app が無い"; return; }
    have_gui || { skip "GUI が無い環境（CI か WindowServer なし）"; return; }
    # 利用者の実データを使わない: 使い捨てのデータ領域に設定・Automation・フィクスチャの会議を置いて起動する。
    # launch_at_login=false と first_run_completed=true で、ログイン項目の登録や初回のメインウィンドウを出さない
    local fix="${ROOT}/Tests/Fixtures/meetings/${E2E_MEETING_ID}"
    mkdir -p "${DATA}/recordings/${E2E_MEETING_ID}" "${DATA}/transcripts/${E2E_MEETING_ID}"
    # claude_path は存在しないパス: 項目 14.1 の統合した会議が待ち行列で要約に進んでも、本物の claude を呼ばない
    printf '{"launch_at_login": false, "first_run_completed": true, "claude_path": "/nonexistent-autonote-e2e/claude"}\n' >"${DATA}/settings.json"
    ( umask 077; cat >"${DATA}/automations.json" <<'JSON'
[{"name": "e2e-echo", "enabled": true, "on": "minutes_generated", "command": "echo \"$AUTONOTE_EVENT $AUTONOTE_MEETING_ID\" > \"$AUTONOTE_E2E_OUT\"", "timeout_sec": 30}]
JSON
    )
    chmod 600 "${DATA}/automations.json"
    cp "${fix}/manifest.json" "${DATA}/recordings/${E2E_MEETING_ID}/manifest.json"
    cp "${fix}/minutes.json" "${DATA}/transcripts/${E2E_MEETING_ID}/minutes.json"
    # 07.4: 最終文字起こしに失敗したジョブ（従来の形式の message）を 1 件置く
    mkdir -p "${DATA}/queue/jobs" "${DATA}/recordings/${E2E_FAILED_MEETING_ID}"
    cp "${ROOT}/Tests/Fixtures/queue/${E2E_FAILED_MEETING_ID}.json" "${DATA}/queue/jobs/${E2E_FAILED_MEETING_ID}.json"
    cp "${ROOT}/Tests/Fixtures/meetings/${E2E_FAILED_MEETING_ID}/manifest.json" \
        "${DATA}/recordings/${E2E_FAILED_MEETING_ID}/manifest.json"
    AUTONOTE_DATA_DIR="${DATA}" AUTONOTE_E2E_OUT="${DATA}/auto-out.txt" "${bin}" >"${WORK}/app.log" 2>&1 &
    APP_PID=$!
    local i alive=0
    for i in $(seq 1 50); do
        sleep 0.1
        kill -0 "${APP_PID}" 2>/dev/null || break
        if (( i >= 20 )) && pgrep -x AutoNoteApp | grep -qx "${APP_PID}"; then alive=1; break; fi
    done
    if [[ "${alive}" -ne 1 ]]; then
        LAST_LOG="${WORK}/app.log"; fail "起動後 5 秒以内にプロセスが消えた"
        APP_PID=""; return
    fi
    # 起動したアプリ（pid）のメニューバー項目を System Events で読む（アクセシビリティ権限が要る）。
    # 見るのはアプリが付ける固定の AXIdentifier（Sources/AutoNoteApp/MenuBarContent.swift の MenuBarLabel.accessibilityID）。
    # 項目の名前は SF Symbol の説明で、OS の言語で変わる（英語「waveform」、日本語「オーディオ波形」）ので判定に使わない。
    # 触れない環境（権限なし・pid で引けない）だけ SKIP。それ以外の失敗（menu bar が無い、時間切れ等）と識別子の違いは FAIL。
    local want="${E2E_EXPECT_STATUS_ITEM_ID:-autonote-status-item}" idx="${E2E_MENUBAR_INDEX:-2}"
    local got="" result="" reason="" n
    for n in 1 2 3 4 5; do
        if app_ax 10 '            set v to value of attribute "AXIdentifier"
            if v is missing value then return "（なし）"
            return (v as text) & " / " & (title as text)'; then
            got="$(cat "${LAST_LOG}")"
            if [[ "${got%% / *}" == "${want}" ]]; then result=pass; break; fi
            result="wrong-id"
        elif reason="$(ax_skip_reason)"; then
            result=untouchable; break
        else
            result=error
        fi
        sleep 1   # 起動直後はメニューバー項目がまだ無いことがあるので、触れない環境以外は再試行する
    done
    pass "生存確認（pid ${APP_PID}）"
    CURRENT="7b. メニューバー項目の識別子 ${want}（pid ${APP_PID} / menu bar ${idx}）"
    case "${result}" in
        pass) pass "「${got}」" ;;
        untouchable) skip "${reason}" ;;
        wrong-id) LAST_LOG=""; fail "メニューバー項目の AXIdentifier / 名前が「${got}」（期待 ${want}）" ;;
        *) fail "osascript が失敗（5 回試行）" ;;
    esac
}

check_first_run_output_folder() {
    CURRENT="07.1 起動後に <DATA>/vault ができ settings.json に書かれる"
    app_or_skip || return
    local i got=""
    for i in $(seq 1 50); do
        got="$(plutil -extract output_folder raw -o - "${DATA}/settings.json" 2>/dev/null)"
        if [[ -d "${DATA}/vault" && "${got}" == "${DATA}/vault" ]]; then pass "${got}"; return; fi
        sleep 0.1
    done
    LAST_LOG="${WORK}/app.log"; fail "5 秒待っても ${DATA}/vault が無いか output_folder が「${got}」"
}

check_first_run_no_download() {
    CURRENT="07.2 AUTONOTE_DATA_DIR 下ではモデルをダウンロードしない"
    app_or_skip || return
    sleep 3
    local models; models="$(find "${DATA}/models" -maxdepth 1 -name 'ggml-*' 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${models}" -eq 0 ]] || { LAST_LOG=""; fail "${DATA}/models に ggml-* が ${models} 個（期待 0）"; return; }
    grep -q "model download skipped (data directory overridden)" "${WORK}/app.log" \
        || { LAST_LOG="${WORK}/app.log"; fail "app.log に「model download skipped (data directory overridden)」が無い"; return; }
    pass "ggml-* 0 個"
}

# 07.3: メニューを開いて項目名を読む。既定の保存先があるので「保存先が見つかりません」は出ない
check_menu_no_folder_warning() {
    CURRENT="07.3 メニューに「保存先が見つかりません」が出ない"
    app_or_skip || return
    # 開くのは項目 7 で起動したアプリ（pid）のメニューだけ。開いた直後に、別の AutoNoteApp のメニューが開いていないかを
    # 見る（宛先の取り違えの見張り）。項目名を読んだら閉じ、閉じたことを確かめる（close_app_menu）。
    # 途中で失敗・時間切れ・中断しても、cleanup が閉じてからアプリを止める
    local names="" code reason="" others_before others_open pid stray="" log closed=1
    others_before=" $(other_app_open_menus)"
    APP_MENU_OPENED=1
    app_ax 15 '            click it
            delay 0.5
            return selected'
    code=$?; log="${LAST_LOG}"
    others_open="$(other_app_open_menus)"
    for pid in ${others_open}; do
        [[ "${others_before}" == *" ${pid} "* ]] && continue
        # 開いたままだとそのアプリは終了の合図に応じなくなるので、その pid のメニューに AXCancel を送って閉じる
        osascript -e "with timeout of 5 seconds
tell application \"System Events\" to tell (first process whose unix id is ${pid}) to tell menu bar item 1 of menu bar ${E2E_MENUBAR_INDEX:-2} to perform action \"AXCancel\" of menu 1
end timeout" >/dev/null 2>&1
        stray+="${pid} "
    done
    if [[ ${code} -eq 0 && -z "${stray}" ]]; then
        app_ax 10 '            return name of every menu item of menu 1'
        code=$?; log="${LAST_LOG}"
    fi
    close_app_menu || closed=0
    LAST_LOG="${log}"
    if [[ -n "${stray}" ]]; then
        LAST_LOG=""; fail "別の AutoNoteApp（pid ${stray% }）のメニューが開いた（宛先の取り違え。閉じる操作は送った）"; return
    fi
    if [[ ${code} -ne 0 ]]; then
        if reason="$(ax_skip_reason)"; then skip "${reason}"; else fail "osascript が失敗（exit ${code}）"; fi
        return
    fi
    [[ "${closed}" -eq 1 ]] || { fail "開いたメニューを閉じられない（アプリは検査の終わりに止める）"; return; }
    names="$(cat "${LAST_LOG}")"
    [[ "${names}" == *録音開始* ]] || { fail "メニュー項目に「録音開始」が無い"; return; }
    [[ "${names}" != *保存先が見つかりません* ]] || { fail "メニュー項目に「保存先が見つかりません」がある"; return; }
    pass "「録音開始」あり、「保存先が見つかりません」なし、メニューは閉じた"
}

# 06.3〜06.6 の前提: 項目 7 で起動したアプリが生きていること。生きていなければ skip して 1 を返す
app_or_skip() {
    if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then return 0; fi
    skip "アプリが起動していない"; return 1
}

check_cli_app_not_running() {
    CURRENT="06.2 アプリ未起動の CLI は自動起動しない"
    cli_or_skip || return
    # この時点で ${DATA} のアプリは未起動（項目 7 の前）。AUTONOTE_DATA_DIR があれば CLI はアプリを起動しない
    AUTONOTE_DATA_DIR="${DATA}" run_timeout 3 "${AUTONOTE_CLI}" status; local code=$?
    [[ ${code} -ne 124 ]] || { fail "3 秒以内に終わらない"; return; }
    [[ ${code} -eq 1 ]] || { fail "exit ${code}（期待 1）"; return; }
    grep -q "AutoNote が起動していません" "${LAST_LOG}" || { fail "メッセージ「AutoNote が起動していません」が無い"; return; }
    pass "exit 1"
}

check_status_over_socket() {
    CURRENT="06.3 autonote status がソケット経由で idle"
    app_or_skip || return
    cli_or_skip || return
    local i
    for i in $(seq 1 100); do [[ -S "${DATA}/autonote.sock" ]] && break; sleep 0.1; done
    [[ -S "${DATA}/autonote.sock" ]] || { LAST_LOG="${WORK}/app.log"; fail "10 秒待っても ${DATA}/autonote.sock ができない"; return; }
    local want="${E2E_EXPECT_RECORDER_STATE:-idle}" out="${WORK}/status.json" code state
    AUTONOTE_DATA_DIR="${DATA}" run_timeout 10 sh -c '"$1" status --json >"$2"' _ "${AUTONOTE_CLI}" "${out}"; code=$?
    [[ ${code} -eq 0 ]] || { fail "status --json: exit ${code}（期待 0）"; return; }
    state="$(plutil -extract status.recorder.state raw -o - - <"${out}" 2>/dev/null)"
    [[ "${state}" == "${want}" ]] || { LAST_LOG="${out}"; fail "recorder.state「${state}」（期待「${want}」）"; return; }
    AUTONOTE_DATA_DIR="${DATA}" run_timeout 10 "${AUTONOTE_CLI}" status; code=$?
    [[ ${code} -eq 0 ]] || { fail "status: exit ${code}（期待 0）"; return; }
    grep -q "録音器: 待機" "${LAST_LOG}" || { fail "人向けの status に「録音器: 待機」が無い"; return; }
    pass "recorder.state ${state}"
}

check_failure_message_compat() {
    CURRENT="07.4 status --json の失敗 message は従来の形式"
    app_or_skip || return
    cli_or_skip || return
    local out="${WORK}/status-07.4.json" code i id="" msg="" want="final_transcription_failed: TranscriptionError"
    AUTONOTE_DATA_DIR="${DATA}" run_timeout 10 sh -c '"$1" status --json >"$2"' _ "${AUTONOTE_CLI}" "${out}"; code=$?
    [[ ${code} -eq 0 ]] || { fail "status --json: exit ${code}（期待 0）"; return; }
    for i in $(seq 0 50); do
        id="$(plutil -extract "status.queue.${i}.meeting_id" raw -o - - <"${out}" 2>/dev/null)" || break
        if [[ "${id}" == "${E2E_FAILED_MEETING_ID}" ]]; then
            msg="$(plutil -extract "status.queue.${i}.message" raw -o - - <"${out}" 2>/dev/null)"; break
        fi
        id=""
    done
    [[ "${id}" == "${E2E_FAILED_MEETING_ID}" ]] || { LAST_LOG="${out}"; fail "status.queue に ${E2E_FAILED_MEETING_ID} が無い"; return; }
    [[ "${msg}" == "${want}" ]] || { LAST_LOG="${out}"; fail "message「${msg}」（期待「${want}」）"; return; }
    pass "${msg}"
}

check_bookmark_not_recording() {
    CURRENT="06.4 録音していないときの bookmark は失敗"
    app_or_skip || return
    cli_or_skip || return
    AUTONOTE_DATA_DIR="${DATA}" run_timeout 10 "${AUTONOTE_CLI}" bookmark; local code=$?
    [[ ${code} -eq 1 ]] || { fail "exit ${code}（期待 1）"; return; }
    grep -q "録音中ではありません" "${LAST_LOG}" || { fail "メッセージ「録音中ではありません」が無い"; return; }
    pass "exit 1"
}

check_automation_run() {
    CURRENT="06.5 Automation の手動実行"
    app_or_skip || return
    cli_or_skip || return
    local want="${E2E_EXPECT_AUTOMATION_OUT:-minutes_generated ${E2E_MEETING_ID}}"
    AUTONOTE_DATA_DIR="${DATA}" run_timeout 30 "${AUTONOTE_CLI}" automations run e2e-echo "${E2E_MEETING_ID}"; local code=$?
    [[ ${code} -eq 0 ]] || { fail "automations run: exit ${code}（期待 0）"; return; }
    local got; got="$(cat "${DATA}/auto-out.txt" 2>/dev/null)"
    [[ "${got}" == "${want}" ]] || { LAST_LOG=""; fail "auto-out.txt「${got}」（期待「${want}」）"; return; }
    pass "${got}"
}

check_recording_main_thread() {
    CURRENT="06.7 録音開始のあと主スレッドが回り続けない"
    app_or_skip || return
    cli_or_skip || return
    # 2026-10-27: メニューバーのラベルの TimelineView が SwiftUI の更新を抜けられず、録音開始から終了まで主スレッドが
    # 100 % で回り、ウィンドウもアクセシビリティも固まった。録音を始めて 3 秒後の CPU と、System Events から
    # メニューバー項目が読めることで再発を見る。マイク許可が無い環境では start が失敗するので skip
    if ! AUTONOTE_DATA_DIR="${DATA}" run_timeout 10 "${AUTONOTE_CLI}" start; then skip "autonote start が失敗（マイク許可が無い環境か）"; return; fi
    sleep 3
    # メニューバー項目は項目 7 で起動したアプリ（pid）のものを読む。経過時間（0:03 の形）は OS の言語に左右されない
    local cpu item="" item_code item_log reason=""
    cpu="$(ps -o %cpu= -p "${APP_PID}" | tr -d ' ')"
    app_ax 10 '            return title'; item_code=$?
    item_log="${LAST_LOG}"
    [[ ${item_code} -eq 0 ]] && item="$(cat "${item_log}")"
    AUTONOTE_DATA_DIR="${DATA}" run_timeout 20 "${AUTONOTE_CLI}" stop || { fail "autonote stop が失敗"; return; }
    [[ "${cpu%.*}" -lt 60 ]] || { LAST_LOG="${WORK}/app.log"; fail "録音開始 3 秒後の CPU が ${cpu} %（期待 60 % 未満）"; return; }
    if [[ ${item_code} -ne 0 ]]; then
        LAST_LOG="${item_log}"
        if reason="$(ax_skip_reason)"; then skip "CPU ${cpu} % は期待どおり。メニューバー項目は読めない: ${reason}"
        else fail "メニューバー項目を読めない（exit ${item_code}。主スレッドが固まっていないか）"; fi
        return
    fi
    [[ "${item}" =~ [0-9]+:[0-9][0-9] ]] || { LAST_LOG=""; fail "メニューバー項目の経過時間が読めない: ${item}"; return; }
    pass "CPU ${cpu} %、メニューバー「${item}」"
}

check_live_summary_default_off() {
    CURRENT="09.3 リアルタイム要約は既定オフ（録音しても要約せず通常どおり止まる）"
    app_or_skip || return
    cli_or_skip || return
    # 項目 7 の settings.json は live_summary_enabled を書かない（既定 false）。マイク許可が無い環境では start が失敗するので skip
    # 同じ app.log には 06.7 の録音の off 行もあるので、start 前の件数から 1 件以上増えることを見る
    local offs_before; offs_before="$(grep -c "live summary: off (" "${WORK}/app.log" 2>/dev/null)"; offs_before="${offs_before:-0}"
    if ! AUTONOTE_DATA_DIR="${DATA}" run_timeout 10 "${AUTONOTE_CLI}" start; then skip "autonote start が失敗（マイク許可が無い環境か）"; return; fi
    sleep 3
    AUTONOTE_DATA_DIR="${DATA}" run_timeout 20 "${AUTONOTE_CLI}" stop || { fail "autonote stop が失敗"; return; }
    local out="${WORK}/status-09.3.json" state="" i
    for i in $(seq 1 20); do
        AUTONOTE_DATA_DIR="${DATA}" run_timeout 5 sh -c '"$1" status --json >"$2"' _ "${AUTONOTE_CLI}" "${out}"
        state="$(plutil -extract status.recorder.state raw -o - - <"${out}" 2>/dev/null)"
        [[ "${state}" == "idle" ]] && break
        sleep 0.5
    done
    [[ "${state}" == "idle" ]] || { LAST_LOG="${out}"; fail "stop から 10 秒で recorder.state が idle にならない（「${state}」）"; return; }
    local offs_after; offs_after="$(grep -c "live summary: off (" "${WORK}/app.log" 2>/dev/null)"; offs_after="${offs_after:-0}"
    [[ "${offs_after}" -gt "${offs_before}" ]] \
        || { LAST_LOG="${WORK}/app.log"; fail "app.log の「live summary: off (」が start 前 ${offs_before} 件から増えていない（${offs_after} 件）"; return; }
    local files; files="$(find "${DATA}/transcripts" -name live-summary.json 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${files}" -eq 0 ]] || { LAST_LOG=""; fail "live-summary.json が ${files} 個（期待 0）"; return; }
    pass "idle、app.log の live summary: off が ${offs_before} → ${offs_after} 件、live-summary.json なし"
}

# 14.1 の補助: 無音の 16 kHz mono 16bit WAV（<秒> 秒）を書く
e2e_le32() { local v=$1; printf '\\x%02x\\x%02x\\x%02x\\x%02x' $((v & 255)) $(((v >> 8) & 255)) $(((v >> 16) & 255)) $(((v >> 24) & 255)); }
e2e_silent_wav() {
    local out=$1 bytes=$(($2 * 32000))
    { printf 'RIFF'; printf '%b' "$(e2e_le32 $((bytes + 36)))"; printf 'WAVEfmt '
      printf '%b' "$(e2e_le32 16)\x01\x00\x01\x00$(e2e_le32 16000)$(e2e_le32 32000)\x02\x00\x10\x00"
      printf 'data'; printf '%b' "$(e2e_le32 "${bytes}")"; head -c "${bytes}" /dev/zero; } >"${out}"
}
# 14.1 の補助: 録音済みの会議を 1 つ置く（<id> <開始 ISO8601> <終了 ISO8601> <live|imported>。音声は 2 秒の無音）
e2e_put_meeting() {
    local dir="${DATA}/recordings/$1"
    mkdir -p "${dir}/tracks"
    e2e_silent_wav "${dir}/tracks/mic-000.wav" 2
    cat >"${dir}/manifest.json" <<JSON
{"id": "$1", "started_at": "$2", "ended_at": "$3", "source": "$4",
 "device": {"name": "E2E Mic", "uid": "E2E-MIC", "transport": "builtin"}, "language": "ja",
 "tracks": [{"track": "mic", "relative_path": "tracks/mic-000.wav", "start_offset": 0, "duration_seconds": 2}],
 "pauses": [], "bookmarks": [], "status": "transcript_only", "silence_warning": false, "autonote_version": "0.4.1"}
JSON
}

# 14.1: 3 本の録音を autonote merge で統合する。取り込み（source=imported）を混ぜると拒否され何も作らない（SPEC §2.2）。
# `autonote import` の会議は imported なので統合できない。そのため live の会議を manifest と WAV で直接置く。
# 統合後の会議はこのアプリの待ち行列に入る。項目 7 の settings.json の claude_path は存在しないパスなので、要約で claude は呼ばれない
check_merge_recordings() {
    CURRENT="14.1 autonote merge で 3 本の録音を 1 つの会議に統合し、統合元は一覧から外れる"
    app_or_skip || return
    cli_or_skip || return
    local ids=(20261020-1000-e001 20261020-1000-e002 20261020-1000-e003) imported=20261020-1000-e004
    e2e_put_meeting "${ids[0]}" 2026-10-20T01:00:00.000Z 2026-10-20T01:00:02.000Z live
    e2e_put_meeting "${ids[1]}" 2026-10-20T01:00:03.000Z 2026-10-20T01:00:05.000Z live
    e2e_put_meeting "${ids[2]}" 2026-10-20T01:00:08.000Z 2026-10-20T01:00:10.000Z live
    e2e_put_meeting "${imported}" 2026-10-20T01:00:12.000Z 2026-10-20T01:00:14.000Z imported
    local before after code
    before="$(ls "${DATA}/recordings" | sort)"
    AUTONOTE_DATA_DIR="${DATA}" run_timeout 30 "${AUTONOTE_CLI}" merge "${ids[2]}" "${imported}"; code=$?
    [[ ${code} -eq 1 ]] || { fail "imported を含む merge: exit ${code}（期待 1）"; return; }
    grep -q "取り込んだ音声の会議は統合できません" "${LAST_LOG}" || { fail "拒否の理由が出ない"; return; }
    after="$(ls "${DATA}/recordings" | sort)"
    [[ "${after}" == "${before}" ]] || { LAST_LOG=""; fail "拒否されたのに recordings/ が変わった"; return; }

    AUTONOTE_DATA_DIR="${DATA}" run_timeout 120 "${AUTONOTE_CLI}" merge "${ids[@]}"; code=$?
    [[ ${code} -eq 0 ]] || { fail "merge: exit ${code}（期待 0）"; return; }
    local new; new="$(sed -n 's/^受け付けました: //p' "${LAST_LOG}")"
    local m="${DATA}/recordings/${new}/manifest.json"
    [[ -n "${new}" && -f "${m}" ]] || { fail "新しい会議の manifest が無い（ID「${new}」）"; return; }
    local key want got i
    for key in tracks.0.start_offset=0 tracks.1.start_offset=3 tracks.2.start_offset=8 \
               pauses.0.start=2 pauses.0.end=3 pauses.1.start=5 pauses.1.end=8; do
        want="${key#*=}"; got="$(plutil -extract "${key%%=*}" raw -o - "${m}" 2>/dev/null)"
        awk -v a="${got}" -v b="${want}" 'BEGIN { exit !(a != "" && a + 0 == b + 0) }' \
            || { LAST_LOG="${m}"; fail "${key%%=*} が「${got}」（期待 ${want}）"; return; }
    done
    for i in 0 1 2; do
        [[ -f "${DATA}/recordings/${new}/tracks/mic-00${i}.wav" ]] || { LAST_LOG=""; fail "tracks/mic-00${i}.wav が無い"; return; }
        [[ "$(plutil -extract "merged_from.${i}" raw -o - "${m}" 2>/dev/null)" == "${ids[${i}]}" ]] \
            || { LAST_LOG="${m}"; fail "merged_from.${i} が ${ids[${i}]} でない"; return; }
        got="$(plutil -extract merged_into raw -o - "${DATA}/recordings/${ids[${i}]}/manifest.json" 2>/dev/null)"
        [[ "${got}" == "${new}" ]] || { LAST_LOG=""; fail "${ids[${i}]} の merged_into が「${got}」（期待 ${new}）"; return; }
    done
    local out="${WORK}/list-14.1.json" listed=" "
    AUTONOTE_DATA_DIR="${DATA}" run_timeout 10 sh -c '"$1" list --json >"$2"' _ "${AUTONOTE_CLI}" "${out}" \
        || { fail "list --json が失敗"; return; }
    for i in $(seq 0 100); do
        got="$(plutil -extract "meetings.${i}.id" raw -o - "${out}" 2>/dev/null)" || break
        listed+="${got} "
    done
    [[ "${listed}" == *" ${new} "* ]] || { LAST_LOG="${out}"; fail "list に新しい会議 ${new} が無い"; return; }
    for i in 0 1 2; do
        [[ "${listed}" != *" ${ids[${i}]} "* ]] || { LAST_LOG="${out}"; fail "list に統合元 ${ids[${i}]} が残っている"; return; }
    done
    pass "${new}: start_offset 0/3/8、pauses 2–3/5–8、統合元 3 件は merged_into 付きで一覧から外れた"
}

check_automation_log_and_socket() {
    CURRENT="06.6 Automation のログとソケットの後始末"
    app_or_skip || return
    local results=( "${DATA}"/logs/automations/*/result.json )
    [[ ${#results[@]} -eq 1 && -f "${results[0]}" ]] || { LAST_LOG=""; fail "result.json が ${#results[@]} 個（期待 1）"; return; }
    local exit_code; exit_code="$(plutil -extract exit_code raw -o - "${results[0]}" 2>/dev/null)"
    [[ "${exit_code}" == "0" ]] || { LAST_LOG="${results[0]}"; fail "result.json の exit_code「${exit_code}」（期待 0）"; return; }
    [[ -f "$(dirname "${results[0]}")/stdout.txt" ]] || { LAST_LOG=""; fail "stdout.txt が無い"; return; }
    kill -TERM "${APP_PID}" 2>/dev/null
    local i
    for i in $(seq 1 50); do [[ -e "${DATA}/autonote.sock" ]] || break; sleep 0.1; done
    [[ ! -e "${DATA}/autonote.sock" ]] || { LAST_LOG="${WORK}/app.log"; fail "SIGTERM から 5 秒でソケットが消えない"; return; }
    for i in $(seq 1 50); do kill -0 "${APP_PID}" 2>/dev/null || break; sleep 0.1; done
    wait "${APP_PID}" 2>/dev/null; APP_PID=""   # 止まらなければ cleanup が kill する
    pass "exit_code 0、SIGTERM でソケットが消えた"
}

check_cer() {
    CURRENT="9. scripts/cer.py の計算"
    [[ -f scripts/cer.py ]] || { skip "scripts/cer.py が無い"; return; }
    command -v python3 >/dev/null || { skip "python3 が無い"; return; }
    printf 'あいうえお\n' >"${WORK}/ref.txt"
    printf 'あいうえお\n' >"${WORK}/hyp-same.txt"
    printf 'あいうえ\n' >"${WORK}/hyp-diff.txt"
    # 引数順は <hyp> <ref>。出力は「<CER> (<距離>/<参照文字数>)」
    if ! run python3 -I scripts/cer.py "${WORK}/hyp-same.txt" "${WORK}/ref.txt"; then fail "同一テキストで異常終了"; return; fi
    local same diff
    same="$(cut -d' ' -f1 "${LAST_LOG}")"
    if ! run python3 -I scripts/cer.py "${WORK}/hyp-diff.txt" "${WORK}/ref.txt"; then fail "差のあるテキストで異常終了"; return; fi
    diff="$(cut -d' ' -f1 "${LAST_LOG}")"
    if [[ "${same}" == "0.0000" && "${diff}" == "0.2000" ]]; then
        pass "同一 ${same} / 1 字欠落 ${diff}"
    else
        fail "同一 ${same}（期待 0.0000）/ 1 字欠落 ${diff}（期待 0.2000）"
    fi
}

check_whisper() {
    CURRENT="10. whisper-cli で先頭 5 秒を文字起こし"
    local cli=tools/whisper.cpp/build/bin/whisper-cli model=tools/whisper.cpp/models/ggml-base.bin wav=tools/samples/ja-5min.wav
    [[ -x "${cli}" ]] || { skip "${cli} が無い（scripts/setup-whisper.sh）"; return; }
    [[ -f "${model}" ]] || { skip "${model} が無い"; return; }
    [[ -f "${wav}" ]] || { skip "${wav} が無い（scripts/make-sample-audio.sh）"; return; }
    local out="${WORK}/whisper.txt"
    # stdout（文字起こし）だけを out に、ログは LAST_LOG に分ける
    local t0=${SECONDS} code
    run_timeout 10 sh -c '"$1" -m "$2" -l ja -t 4 -d 5000 -nt -np -f "$3" >"$4"' _ "${cli}" "${model}" "${wav}" "${out}"
    code=$?
    if [[ ${code} -eq 124 ]]; then fail "10 秒以内に終わらない"; return; fi
    if [[ ${code} -ne 0 ]]; then fail "whisper-cli が exit ${code}"; return; fi
    local elapsed=$((SECONDS - t0))
    local text
    text="$(tr -d '[:space:]' <"${out}")"
    if [[ -n "${text}" ]]; then pass "${elapsed} 秒「$(head -c 60 <<<"${text}")」"; else fail "文字起こしが空"; fi
}

check_results_doc() {
    CURRENT="11. スパイク結果表の 12 見出し"
    local doc=docs/superpowers/research/2026-10-24-spike-results.md
    LAST_LOG=""
    [[ -f "${doc}" ]] || { fail "${doc} が無い"; return; }
    local missing=() i
    for i in $(seq 1 12); do
        grep -q "^## 項目 ${i}:" "${doc}" || missing+=("${i}")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then pass; else fail "見出しが無い項目: ${missing[*]}"; fi
}

check_fake_transcript() {
    CURRENT="12. scripts/make-fake-transcript.py で偽の文字起こし"
    # 既定の入力はコミット済みの scripts/samples/ja-5min.txt（tools/ の無い新しい clone でも動く）
    [[ -f scripts/samples/ja-5min.txt ]] || { skip "入力 scripts/samples/ja-5min.txt が無い"; return; }
    command -v python3 >/dev/null || { skip "python3 が無い"; return; }
    if ! run python3 -I scripts/make-fake-transcript.py --minutes 1; then fail "make-fake-transcript.py が 0 以外で終了"; return; fi
    local lines bad
    lines=$(grep -c . "${LAST_LOG}" || true)
    bad=$(grep -v -c -E '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] (自分|相手): ' "${LAST_LOG}" || true)
    if [[ "${lines}" -eq 0 ]]; then fail "出力が空"; return; fi
    if [[ "${bad}" -ne 0 ]]; then fail "[HH:MM:SS] 自分|相手: 形式でない行が ${bad} 行"; return; fi
    if ! run python3 -I scripts/make-fake-transcript.py --minutes 2 --inject; then fail "--inject が 0 以外で終了"; return; fi
    if [[ "$(grep -c 'HACKED' "${LAST_LOG}" || true)" -ne 1 ]]; then fail "--inject の注入行が 1 行でない"; return; fi
    LAST_LOG=""; pass "${lines} 行、注入行あり"
}

check_claude_probe_files() {
    CURRENT="13. scripts/minutes-schema.json と probe-claude.sh の静的確認"
    if ! run jq -e '(.required | sort) == (["agenda","architecture_diagram","attendees","deadlines","decisions","follow_ups","insights","key_points","next_actions","questions","risks","schema_version","suggested_terms","summary","title"]) and .additionalProperties == false and .properties.title.maxLength == 20 and .properties.summary.minItems == 3 and .properties.summary.maxItems == 5 and .properties.next_actions.items.properties.priority.enum == ["high","medium","low"]' scripts/minutes-schema.json; then
        fail "minutes-schema.json が JSON でない、または必須キー・制約が違う"; return
    fi
    if ! run bash -n scripts/probe-claude.sh; then fail "probe-claude.sh に構文エラー"; return; fi
    LAST_LOG=""; pass "（claude の実呼び出しは費用がかかるので E2E では行わない）"
}

check_bt_verify_script() {
    CURRENT="17. scripts/bt-verify.sh の静的確認（構文・計測プログラムのコンパイル・--dry-run）"
    if ! run bash -n scripts/bt-verify.sh; then fail "bt-verify.sh に構文エラー"; return; fi
    if ! run python3 -I -m py_compile scripts/bt-verify.py; then fail "bt-verify.py に構文エラー"; return; fi
    # --dry-run は何も鳴らさず・つながず・起動しない（既定の入出力を読むだけ）。--bt-name なしでも exit 0
    local code
    run_timeout 180 scripts/bt-verify.sh --dry-run --out "${WORK}/bt-verify-dry" </dev/null; code=$?
    [[ ${code} -eq 0 ]] || { fail "--dry-run が exit ${code}"; return; }
    grep -q '\[dry-run\] nothing was played' "${LAST_LOG}" || { fail "--dry-run の終わりの行が無い"; return; }
    LAST_LOG=""; pass "（実機の Bluetooth での実行は scripts/bt-verify.sh --bt-name <名前の一部>）"
}

check_render_fixture() {
    CURRENT="01.1 render-fixture が golden と一致"
    cli_or_skip || return
    local out="${WORK}/render-fixture"
    run "${AUTONOTE_CLI}" dev render-fixture --out "${out}" --fixtures "${ROOT}/Tests/Fixtures" || { fail "render-fixture が 0 以外で終了"; return; }
    [[ -f "${out}/_index.md" ]] || { LAST_LOG=""; fail "_index.md が書かれていない"; return; }
    pass "$(tail -n 1 "${LAST_LOG}")"
}

check_render_fixture_detects_diff() {
    CURRENT="01.2 render-fixture が golden との差を検出して exit 1"
    cli_or_skip || return
    local fx="${WORK}/fixtures-tampered"; cp -R "${ROOT}/Tests/Fixtures" "${fx}"; printf '改ざん\n' >>"${fx}/expected/_index.md"
    run "${AUTONOTE_CLI}" dev render-fixture --out "${WORK}/render-tampered" --fixtures "${fx}"; local code=$?
    [[ ${code} -eq 1 ]] || { fail "exit ${code}（期待 1）"; return; }
    grep -q '差分: _index.md' "${LAST_LOG}" || { fail "「差分: _index.md」が出ていない"; return; }
    pass
}

check_dev_record() {
    CURRENT="02.1 dev record で 5 秒の WAV と manifest"
    cli_or_skip || return
    run "${AUTONOTE_CLI}" dev record --check-permission
    grep -q '"mic_permission":"authorized"' "${LAST_LOG}" || { skip "マイク許可がない（責任プロセス: ターミナル）"; return; }
    local out="${WORK}/rec" code
    run_timeout 40 "${AUTONOTE_CLI}" dev record --seconds 5 --out "${out}"; code=$?
    # start gives up after 10 s and stop after 5 s per source, so 40 s means a hang (regression), never a pending dialog.
    [[ ${code} -eq 124 ]] && { fail "hang: 40 秒で終わらない（start/stop のタイムアウトが効いていない）"; return; }
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    local json; json="$(grep '^{' "${LAST_LOG}" | tail -n 1)"
    local status manifest
    status="$(printf '%s' "${json}" | plutil -extract status raw -o - - 2>/dev/null)"
    manifest="$(printf '%s' "${json}" | plutil -extract manifest raw -o - - 2>/dev/null)"
    [[ "${status}" == "too_short" ]] || { fail "status=${status}（期待 too_short）"; return; }
    [[ -f "${manifest}" ]] || { fail "manifest が無い: ${manifest}"; return; }
    [[ "$(plutil -extract status raw -o - "${manifest}" 2>/dev/null)" == "${status}" ]] || { fail "manifest の status が JSON と違う"; return; }
    local wav info
    for wav in "$(dirname "${manifest}")"/tracks/*.wav; do
        info="$(afinfo "${wav}" 2>&1)"
        grep -q '16000 Hz' <<<"${info}" && grep -q '1 ch' <<<"${info}" && grep -qE 'Int16|I16' <<<"${info}" \
            || { LAST_LOG=""; fail "${wav##*/} が 16 kHz / 1 ch / 16 bit でない"; return; }
    done
    # System source failed (e.g. permission dialog pending: start gives up after its 10 s timeout and the mic records
    # alone, so the 5 s length cannot hold). The WAV formats above are still verified; the length check needs the permission.
    if grep -q 'sourceFailed(system)' <<<"${json}"; then
        skip "システム音声の開始に失敗（許可が未応答なら 10 秒で timeout してマイクのみ録音: mic=$(printf '%s' "${json}" | plutil -extract tracks.0.seconds raw -o - - 2>/dev/null)s、WAV 形式は確認済み）。Terminal.app から scripts/e2e-check.sh を実行するか、許可ダイアログに応答してください"
        return
    fi
    local i seconds
    for i in 0 1; do
        seconds="$(printf '%s' "${json}" | plutil -extract "tracks.${i}.seconds" raw -o - - 2>/dev/null)"
        awk -v s="${seconds}" 'BEGIN { exit !(s >= 4.5 && s <= 5.5) }' || { fail "tracks.${i}.seconds=${seconds}（期待 5.0±0.5）"; return; }
    done
    pass "system chunks=$(printf '%s' "${json}" | plutil -extract tracks.1.chunks raw -o - - 2>/dev/null)"
}

check_dev_import() {
    CURRENT="02.2 dev import で m4a / wav を 16k mono WAV に"
    command -v say >/dev/null 2>&1 || { skip "say が無い"; return; }
    cli_or_skip || return
    local dir="${WORK}/imp-src"; mkdir -p "${dir}"
    run say -o "${dir}/s.aiff" "テストです" || { fail "say が失敗"; return; }
    run afconvert -f m4af -d aac "${dir}/s.aiff" "${dir}/s.m4a" || { fail "afconvert (m4a) が失敗"; return; }
    run afconvert -f WAVE -d LEI16@44100 "${dir}/s.aiff" "${dir}/s.wav" || { fail "afconvert (wav) が失敗"; return; }
    local f json manifest wav info
    for f in s.m4a s.wav; do
        run "${AUTONOTE_CLI}" dev import "${dir}/${f}" --out "${WORK}/imp" --start 2026-10-20T10:00:00+09:00 || { fail "${f}: dev import が 0 以外で終了"; return; }
        json="$(grep '^{' "${LAST_LOG}" | tail -n 1)"
        manifest="$(printf '%s' "${json}" | plutil -extract manifest raw -o - - 2>/dev/null)"
        wav="$(printf '%s' "${json}" | plutil -extract wav raw -o - - 2>/dev/null)"
        [[ -f "${manifest}" ]] || { fail "${f}: manifest が無い"; return; }
        [[ "$(plutil -extract source raw -o - "${manifest}")" == "imported" ]] || { fail "${f}: source != imported"; return; }
        [[ "$(plutil -extract device.name raw -o - "${manifest}")" == "import" ]] || { fail "${f}: device.name != import"; return; }
        [[ "$(plutil -extract tracks.0.relative_path raw -o - "${manifest}")" == "tracks/import-000.wav" ]] || { fail "${f}: tracks.0.relative_path が違う"; return; }
        info="$(afinfo "${wav}" 2>&1)"
        grep -q '16000 Hz' <<<"${info}" && grep -q '1 ch' <<<"${info}" || { LAST_LOG=""; fail "${f}: WAV が 16 kHz / 1 ch でない"; return; }
    done
    pass "m4a / wav とも imported・16 kHz mono"
}

check_dev_devices() {
    CURRENT="03.1 dev devices が接続中の入力を 1 行以上の JSON で出す"
    cli_or_skip || return
    if ! system_profiler SPAudioDataType 2>/dev/null | grep -q 'Input Channels'; then skip "入力デバイスが無い Mac"; return; fi
    run_timeout 10 "${AUTONOTE_CLI}" dev devices; local code=$?
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    local lines; lines=$(grep -c . "${LAST_LOG}" || true)
    [[ "${lines}" -ge 1 ]] || { fail "出力が空"; return; }
    if ! python3 -I -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
keys={"name","device_uid","model_uid","transport","input_channels","uid_kind","candidate"}
assert rows and all(set(r)==keys for r in rows)' "${LAST_LOG}" 2>/dev/null; then
        fail "JSON として読めない、またはキー集合が違う行がある"; return
    fi
    pass "${lines} 行"
}

check_dev_devices_watch() {
    CURRENT="03.2 dev devices --watch が present を流し SIGINT で exit 0"
    cli_or_skip || return
    new_log
    "${AUTONOTE_CLI}" dev devices --watch >"${LAST_LOG}" 2>&1 &
    local pid=$! i
    for i in $(seq 1 50); do
        grep -q '"event":"present"' "${LAST_LOG}" && break
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.1
    done
    local present
    present=$(grep -c '"event":"present"' "${LAST_LOG}" || true)
    kill -INT "${pid}" 2>/dev/null
    local code waited=0
    while kill -0 "${pid}" 2>/dev/null && (( waited < 30 )); do sleep 0.1; waited=$((waited + 1)); done
    if kill -0 "${pid}" 2>/dev/null; then kill -9 "${pid}" 2>/dev/null; wait "${pid}" 2>/dev/null; fail "SIGINT から 3 秒で終わらない"; return; fi
    wait "${pid}"; code=$?
    if [[ "${present}" -lt 1 ]]; then fail "present の行が無い"; return; fi
    if ! python3 -I -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1]) if l.strip()]' "${LAST_LOG}" 2>/dev/null; then
        fail "JSON として読めない行がある"; return
    fi
    if grep '"event":"present"' "${LAST_LOG}" | grep -q '"at"'; then fail "present の行に at がある"; return; fi
    if [[ ${code} -ne 0 ]]; then fail "SIGINT 後の終了コードが ${code}（期待 0）"; return; fi
    pass "present ${present} 行、exit 0"
}

check_dev_auto_record_quit() {
    CURRENT="03.3 dev auto-record が quit で終わる"
    cli_or_skip || return
    new_log
    ( printf 'quit\n' | "${AUTONOTE_CLI}" dev auto-record --vault "${WORK}/ar-vault" --data "${WORK}/ar-data" ) >"${LAST_LOG}" 2>&1 &
    local pid=$! code waited=0
    while kill -0 "${pid}" 2>/dev/null && (( waited < 200 )); do sleep 0.1; waited=$((waited + 1)); done
    if kill -0 "${pid}" 2>/dev/null; then pkill -P "${pid}" 2>/dev/null; kill -9 "${pid}" 2>/dev/null; wait "${pid}" 2>/dev/null; fail "quit から 20 秒で終わらない"; return; fi
    wait "${pid}"; code=$?
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    local first; first="$(head -n 1 "${LAST_LOG}")"
    grep -q '"kind":"status"' <<<"${first}" && grep -q '"state":"idle"' <<<"${first}" || { fail "1 行目が status/idle でない: ${first}"; return; }
    pass "status idle の後 exit 0"
}

check_dev_engines() {
    CURRENT="04.1 dev engines が機種とエンジン一覧の JSON を出す"
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    cli_or_skip || return
    # --data は空の作業ディレクトリ（利用者の設定・モデルに左右されないように）
    # stdout だけを別ファイルに取り、jq はそれを読む（stderr の行で JSON が壊れないように。stderr は LAST_LOG へ）
    local out="${WORK}/engines.json"
    run_timeout 30 sh -c '"$1" dev engines --data "$2" >"$3"' _ "${AUTONOTE_CLI}" "${WORK}/engines-data" "${out}"; local code=$?
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    if jq -e '(.machine == "intel" or .machine == "appleSilicon") and (.live | length > 0) and .defaults.batch.model == "large-v3-turbo"' \
        "${out}" >/dev/null 2>&1; then
        pass "machine $(jq -r .machine "${out}")、resolved.live $(jq -r '.resolved.live.kind // "null"' "${out}")"
    else
        fail "machine / live / defaults.batch.model が期待と違う（または JSON でない）"
    fi
}

# 日本語ボイス: scripts/make-sample-audio.sh と同じ選び方（JA_VOICE → Kyoko → say -v '?' の ja_JP の先頭）。無ければ空
ja_voice() {
    if [[ -n "${JA_VOICE:-}" ]]; then printf '%s' "${JA_VOICE}"; return; fi
    if say -v '?' 2>/dev/null | grep -q '^Kyoko '; then printf 'Kyoko'; return; fi
    say -v '?' 2>/dev/null | grep 'ja_JP' | head -1 | sed -E 's/ +ja_JP.*//; s/ *\(.*\)$//'
}

# dev transcribe の出力（LAST_LOG の JSON 行）から、本文のある確定の件数
count_finals() { grep '^{' "${LAST_LOG}" | jq -s '[.[] | select(.final == true and (.text | length > 0))] | length' 2>/dev/null || echo 0; }

check_dev_transcribe_dictation() {
    CURRENT="04.2 dev transcribe dictation が say の短い WAV を文字にする"
    command -v say >/dev/null 2>&1 || { skip "say が無い"; return; }
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    local voice; voice="$(ja_voice)"
    [[ -n "${voice}" ]] || { skip "日本語ボイスが無い"; return; }
    cli_or_skip || return
    run say -v "${voice}" --file-format=WAVE --data-format=LEI16@16000 -o "${WORK}/short.wav" "本日の定例を始めます。議題は三つです。" \
        || { fail "say が失敗"; return; }
    run_timeout 60 "${AUTONOTE_CLI}" dev transcribe "${WORK}/short.wav" --engine dictation; local code=$?
    if [[ ${code} -eq 3 ]]; then skip "$(grep -m 1 '^unavailable:' "${LAST_LOG}")"; return; fi
    if [[ ${code} -eq 124 ]]; then fail "60 秒以内に終わらない"; return; fi
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    local finals; finals="$(count_finals)"
    if [[ "${finals}" -ge 1 ]]; then pass "${voice}、確定 ${finals} 件"; else fail "本文のある確定が無い"; fi
}

# 04.3 / 04.4 共通: ggml-base で ja-5min.wav の先頭 10 秒を <engine> で文字起こしする
dev_transcribe_whisper_head() {
    local engine="$1"
    [[ "${QUICK}" -eq 1 ]] && { skip "--quick"; return; }
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    local model=tools/whisper.cpp/models/ggml-base.bin wav=tools/samples/ja-5min.wav
    [[ -f "${wav}" ]] || { skip "${wav} が無い（scripts/make-sample-audio.sh）"; return; }
    [[ -f "${model}" ]] || { skip "${model} が無い（scripts/setup-whisper.sh）"; return; }
    cli_or_skip || return
    run_timeout 180 "${AUTONOTE_CLI}" dev transcribe "${wav}" --engine "${engine}" --model-path "${model}" --max-seconds 10; local code=$?
    if [[ ${code} -eq 3 ]]; then skip "$(grep -m 1 '^unavailable:' "${LAST_LOG}")"; return; fi
    if [[ ${code} -eq 124 ]]; then fail "180 秒以内に終わらない"; return; fi
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    local finals late
    finals="$(count_finals)"
    late="$(grep '^{' "${LAST_LOG}" | jq -s '[.[] | select(has("start") and .start >= 10.5)] | length' 2>/dev/null || echo 1)"
    [[ "${finals}" -ge 1 ]] || { fail "本文のある確定が無い"; return; }
    [[ "${late}" -eq 0 ]] || { fail "start ≥ 10.5 の発話が ${late} 件"; return; }
    pass "確定 ${finals} 件、$(grep '"summary"' "${LAST_LOG}" | jq -r '"RTF \(.summary.rtf)"')"
}

check_dev_transcribe_whisper() {
    CURRENT="04.3 dev transcribe whisper が base で先頭 10 秒を文字にする"
    dev_transcribe_whisper_head whisper
}

check_dev_transcribe_whisper_live() {
    CURRENT="04.4 dev transcribe whisper-live が base で先頭 10 秒を文字にする"
    dev_transcribe_whisper_head whisper-live
}

# 08.x 共通: 16 kHz mono 16-bit の WAV を書く（1 秒の 440 Hz（振幅 8000）+ 2 秒の無音を繰り返す）。python3 の標準ライブラリだけ
make_tone_wav() {   # make_tone_wav <出力> <秒>
    python3 -I -c 'import math,struct,sys,wave
sec=int(sys.argv[2]); unit=b"".join(struct.pack("<h",int(8000*math.sin(2*math.pi*440*i/16000))) for i in range(16000))+b"\0"*64000
w=wave.open(sys.argv[1],"wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
for _ in range(sec//3): w.writeframesraw(unit)
w.close()' "$1" "$2"
}
DUMMY_GGML=tools/whisper.cpp/models/for-tests-ggml-tiny.bin   # 推論は空振りするが、読み込み・変換・メルは実モデルと同じ（監査 C）

check_dev_transcribe_whisper_resampled() {
    CURRENT="08.2 dev transcribe whisper が 44.1 kHz ステレオの WAV を変換して窓で流す"
    [[ "${QUICK}" -eq 1 ]] && { skip "--quick"; return; }
    command -v python3 >/dev/null 2>&1 || { skip "python3 が無い"; return; }
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    [[ -f "${DUMMY_GGML}" ]] || { skip "${DUMMY_GGML} が無い（scripts/setup-whisper.sh）"; return; }
    cli_or_skip || return
    run make_tone_wav "${WORK}/t30.wav" 30 || { fail "make_tone_wav が失敗"; return; }
    run afconvert -f WAVE -d LEI16@44100 -c 2 "${WORK}/t30.wav" "${WORK}/t30-44k.wav" || { fail "afconvert が失敗"; return; }
    run_timeout 120 "${AUTONOTE_CLI}" dev transcribe "${WORK}/t30-44k.wav" --engine whisper --model-path "${DUMMY_GGML}"; local code=$?
    if [[ ${code} -eq 124 ]]; then fail "120 秒以内に終わらない"; return; fi
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    grep -q '文字起こし 窓 1/1（' "${LAST_LOG}" || { fail "「文字起こし 窓 1/1（」の行が無い"; return; }
    local secs; secs="$(grep '"summary"' "${LAST_LOG}" | jq -r '.summary.audio_seconds' 2>/dev/null)"
    jq -en --argjson s "${secs:-null}" '$s >= 29.9 and $s <= 30.1' >/dev/null 2>&1 \
        || { fail "summary.audio_seconds「${secs}」（期待 29.9〜30.1）"; return; }
    pass "audio_seconds ${secs}"
}

check_batch_memory_flat() {
    CURRENT="08.1 dev transcribe whisper の peak footprint が 10 分と 60 分で 50 MB 以内（max RSS は 250 MB 以内）"
    [[ "${QUICK}" -eq 1 ]] && { skip "--quick"; return; }
    command -v python3 >/dev/null 2>&1 || { skip "python3 が無い"; return; }
    [[ -f "${DUMMY_GGML}" ]] || { skip "${DUMMY_GGML} が無い（scripts/setup-whisper.sh）"; return; }
    cli_or_skip || return
    local rss10 rss60 fp10 fp60 min
    for min in 10 60; do
        run make_tone_wav "${WORK}/m${min}.wav" $((min * 60)) || { fail "make_tone_wav が失敗（${min} 分）"; rm -f "${WORK}"/m10.wav "${WORK}"/m60.wav; return; }
    done
    run_timeout 600 /usr/bin/time -l "${AUTONOTE_CLI}" dev transcribe "${WORK}/m10.wav" --engine whisper --model-path "${DUMMY_GGML}"; local code=$?
    rm -f "${WORK}/m10.wav"
    if [[ ${code} -eq 124 ]]; then fail "10 分の WAV が 600 秒以内に終わらない"; rm -f "${WORK}/m60.wav"; return; fi
    [[ ${code} -eq 0 ]] || { fail "10 分: exit ${code}（期待 0）"; rm -f "${WORK}/m60.wav"; return; }
    grep -q '文字起こし 窓 1/1（' "${LAST_LOG}" || { fail "10 分: 「文字起こし 窓 1/1（」の行が無い"; rm -f "${WORK}/m60.wav"; return; }
    rss10="$(awk '/maximum resident set size/ {print $1}' "${LAST_LOG}")"
    fp10="$(awk '/peak memory footprint/ {print $1}' "${LAST_LOG}")"
    run_timeout 600 /usr/bin/time -l "${AUTONOTE_CLI}" dev transcribe "${WORK}/m60.wav" --engine whisper --model-path "${DUMMY_GGML}"; code=$?
    rm -f "${WORK}/m60.wav"
    if [[ ${code} -eq 124 ]]; then fail "60 分の WAV が 600 秒以内に終わらない"; return; fi
    [[ ${code} -eq 0 ]] || { fail "60 分: exit ${code}（期待 0）"; return; }
    rss60="$(awk '/maximum resident set size/ {print $1}' "${LAST_LOG}")"
    fp60="$(awk '/peak memory footprint/ {print $1}' "${LAST_LOG}")"
    local last; last="$(grep -o '文字起こし 窓 [0-9]*/[0-9]*（' "${LAST_LOG}" | tail -n 1 | sed -E 's/.*窓 ([0-9]+)\/([0-9]+)（/\1 \2/')"
    local wi="${last% *}" wn="${last#* }"
    if [[ -z "${last}" || "${wi}" != "${wn}" || "${wn}" -lt 5 ]]; then fail "60 分: 最後の窓の行が「窓 N/N」（N >= 5）でない（「${last}」）"; return; fi
    if [[ -z "${rss10}" || -z "${rss60}" || -z "${fp10}" || -z "${fp60}" ]]; then fail "max RSS / peak footprint を読めない（RSS ${rss10}/${rss60}, footprint ${fp10}/${fp60}）"; return; fi
    detail="RSS $((rss10 / 1048576))→$((rss60 / 1048576)) MB, footprint $((fp10 / 1048576))→$((fp60 / 1048576)) MB（窓 ${wn} 個）"
    if (( fp60 - fp10 > 52428800 )); then fail "peak footprint の差が 50 MiB を超えた: ${detail}"
    elif (( rss60 - rss10 > 262144000 )); then fail "max RSS の差が 250 MiB を超えた: ${detail}"
    else pass "${detail}"; fi
}

# 05.1 / 05.2 共通: 架空の Transcript と MinutesOutput を ${WORK} に書く
write_dev_summarize_inputs() {
    cat >"${WORK}/summarize-transcript.json" <<'JSON'
{"engine":"fake","language":"ja","utterances":[
{"start":5,"end":9,"speaker":"unknown","text":"それでは定例を始めます","is_final":true},
{"start":40,"end":45,"speaker":"unknown","text":"リリースは来週に出す方向で合意しました","is_final":true},
{"start":80,"end":85,"speaker":"unknown","text":"ドキュメントの更新が残っています","is_final":true}]}
JSON
    cat >"${WORK}/summarize-minutes.json" <<'JSON'
{"title":"架空の定例","summary":["リリースは来週","ドキュメント更新が残る","次回は来週"],
"decisions":[{"text":"リリースは来週に出す","t":"00:00:40"}],"agenda":[],"next_actions":[],"suggested_terms":[]}
JSON
}

check_dev_summarize() {
    CURRENT="05.1 dev summarize --fake で議事録ファイルと _index.md ができる"
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    cli_or_skip || return
    write_dev_summarize_inputs
    local out="${WORK}/summarize-1.json"
    run_timeout 60 sh -c '"$1" dev summarize --fake "$2" --minutes "$3" --out "$4" >"$5"' _ "${AUTONOTE_CLI}" \
        "${WORK}/summarize-transcript.json" "${WORK}/summarize-minutes.json" "${WORK}/s1" "${out}"; local code=$?
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    [[ "$(jq -r .status "${out}")" == "minutes_generated" ]] || { fail "status が minutes_generated でない: $(cat "${out}")"; return; }
    local file note
    file="$(jq -r .file "${out}")"; note="${WORK}/s1/vault/${file}"
    [[ -f "${note}" ]] || { fail "${note} が無い"; return; }
    grep -q 'status: minutes_generated' "${note}" && grep -q '## 決定事項' "${note}" && grep -q '\^t00-00-05' "${note}" \
        || { fail "議事録ファイルに status / 決定事項 / ^t00-00-05 のどれかが無い"; return; }
    grep -qF "$(basename "${file}" .md)" "${WORK}/s1/vault/_index.md" || { fail "_index.md にファイル名の行が無い"; return; }
    local jobs; jobs="$(find "${WORK}/s1/app/queue/jobs" -name '*.json' | wc -l | tr -d ' ')"
    if [[ "${jobs}" -eq 1 ]]; then pass "${file}"; else fail "queue/jobs の JSON が ${jobs} 個（期待 1）"; fi
}

check_dev_summarize_failure() {
    CURRENT="05.2 議事録生成の失敗で transcript_only の秒付きファイルになる"
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    cli_or_skip || return
    write_dev_summarize_inputs
    local out="${WORK}/summarize-2.json"
    run_timeout 60 sh -c '"$1" dev summarize --fake "$2" --fail-summary --out "$3" >"$4"' _ "${AUTONOTE_CLI}" \
        "${WORK}/summarize-transcript.json" "${WORK}/s2" "${out}"; local code=$?
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    local file; file="$(jq -r .file "${out}")"
    [[ "$(basename "${file}")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}\.md$ ]] || { fail "ファイル名が秒付きでない: ${file}"; return; }
    if grep -q 'status: transcript_only' "${WORK}/s2/vault/${file}"; then pass "${file}"; else fail "本文に status: transcript_only が無い"; fi
}

check_dev_summarize_minutes_out() {
    CURRENT="05.3 dev summarize --minutes-out で MinutesOutput の JSON が出る（評価用）"
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    cli_or_skip || return
    write_dev_summarize_inputs
    local out="${WORK}/summarize-3.json" minutes="${WORK}/s3-out/minutes.json"
    run_timeout 60 sh -c '"$1" dev summarize --fake "$2" --minutes "$3" --out "$4" --minutes-out "$5" >"$6"' _ "${AUTONOTE_CLI}" \
        "${WORK}/summarize-transcript.json" "${WORK}/summarize-minutes.json" "${WORK}/s3" "${minutes}" "${out}"; local code=$?
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    if jq -e '.title == "架空の定例" and (.decisions | length) == 1 and has("next_actions")' "${minutes}" >/dev/null 2>&1; then
        pass "${minutes##*/}"
    else
        fail "--minutes-out の JSON が MinutesOutput でない: $(head -c 200 "${minutes}" 2>/dev/null)"
    fi
}

check_eval_unit_tests() {
    CURRENT="15. scripts/eval の単体テスト（評価の正規化・採点）"
    command -v python3 >/dev/null 2>&1 || { skip "python3 が無い"; return; }
    if run python3 -I -m unittest discover -s scripts/eval/tests; then pass; else fail "python3 -I -m unittest discover -s scripts/eval/tests が失敗"; fi
}

# 09.1 / 09.2 共通: 架空の確定発話を 2 段階（live-1 は 05.x と同じ 3 発話、live-2 はそれに 2 発話を足す）で ${WORK} に書く
write_dev_live_summary_inputs() {
    cat >"${WORK}/live-1.json" <<'JSON'
{"engine":"fake","language":"ja","utterances":[
{"start":5,"end":9,"speaker":"unknown","text":"それでは定例を始めます","is_final":true},
{"start":40,"end":45,"speaker":"unknown","text":"リリースは来週に出す方向で合意しました","is_final":true},
{"start":80,"end":85,"speaker":"unknown","text":"ドキュメントの更新が残っています","is_final":true}]}
JSON
    cat >"${WORK}/live-2.json" <<'JSON'
{"engine":"fake","language":"ja","utterances":[
{"start":5,"end":9,"speaker":"unknown","text":"それでは定例を始めます","is_final":true},
{"start":40,"end":45,"speaker":"unknown","text":"リリースは来週に出す方向で合意しました","is_final":true},
{"start":80,"end":85,"speaker":"unknown","text":"ドキュメントの更新が残っています","is_final":true},
{"start":100,"end":110,"speaker":"unknown","text":"資料は佐藤さんが送ります","is_final":true},
{"start":120,"end":130,"speaker":"unknown","text":"次回は来週の火曜です","is_final":true}]}
JSON
}

check_dev_live_summary_shape() {
    CURRENT="09.1 dev live-summary が状態の JSON を 1 行で出す"
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    cli_or_skip || return
    write_dev_live_summary_inputs
    # --claude を付けない（決定的な FakeLiveSummarizer）。本物の claude は呼ばない
    local out="${WORK}/ls-1.json"
    run_timeout 30 sh -c '"$1" dev live-summary "$2" >"$3"' _ "${AUTONOTE_CLI}" "${WORK}/live-1.json" "${out}"; local code=$?
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    [[ "$(wc -l <"${out}" | tr -d ' ')" -eq 1 ]] || { LAST_LOG="${out}"; fail "出力が 1 行でない"; return; }
    jq -e '(.now|type=="string") and (.decisions|type=="array") and (.todos|type=="array")
           and (.todos[0]|has("text") and has("owner")) and .todos[0].side == "self"
           and .consumed_through == 85 and (.updated_at|type=="string") and (has("asked_question_ids")|not)' \
        "${out}" >/dev/null || { LAST_LOG="${out}"; fail "状態の形が違う: $(cat "${out}")"; return; }
    pass "consumed_through 85"
}

check_dev_live_summary_accumulates() {
    CURRENT="09.2 dev live-summary の 2 回目が前回のリストと consumed_through を引き継ぐ"
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    cli_or_skip || return
    local first="${WORK}/ls-1.json" out="${WORK}/ls-2.json" again="${WORK}/ls-3.json" code
    [[ -s "${first}" ]] || { LAST_LOG=""; fail "09.1 の ${first} が無い"; return; }
    run_timeout 30 sh -c '"$1" dev live-summary "$2" --state "$3" >"$4"' _ "${AUTONOTE_CLI}" \
        "${WORK}/live-2.json" "${first}" "${out}"; code=$?
    [[ ${code} -eq 0 ]] || { fail "2 回目: exit ${code}（期待 0）"; return; }
    jq -e --slurpfile prev "${first}" '(.decisions|length) == 2 and .decisions[0] == $prev[0].decisions[0]
           and (.todos|length) == 2 and .consumed_through == 130' "${out}" >/dev/null \
        || { LAST_LOG="${out}"; fail "2 回目が前回を引き継いでいない: $(cat "${out}")"; return; }
    run_timeout 30 sh -c '"$1" dev live-summary "$2" --state "$3" >"$4"' _ "${AUTONOTE_CLI}" \
        "${WORK}/live-2.json" "${out}" "${again}"; code=$?
    [[ ${code} -eq 0 ]] || { fail "3 回目: exit ${code}（期待 0）"; return; }
    jq -e --slurpfile prev "${out}" '. == $prev[0]' "${again}" >/dev/null \
        || { LAST_LOG="${again}"; fail "新しい発話が無いのに状態が変わった: $(cat "${again}")"; return; }
    pass "決定 2 件・宿題 2 件、consumed_through 130、新しい発話なしで不変"
}

check_dev_live_summary_questions() {
    CURRENT="09.4 dev live-summary --questions が聞けた項目を印し、2 回目には聞けた項目を渡さない"
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    cli_or_skip || return
    write_dev_live_summary_inputs
    # 架空の聞きたいこと 2 件。偽の要約器は渡された未確定の先頭 1 件を「聞けた」にする
    cat >"${WORK}/q-1.json" <<'JSON'
{"items":[{"id":"q1","text":"会場のキャパシティ"},{"id":"q2","text":"入館証の締め切り","asked":false,"asked_by":null}]}
JSON
    local first="${WORK}/lq-1.json" second="${WORK}/lq-2.json" code
    run_timeout 30 sh -c '"$1" dev live-summary "$2" --questions "$3" >"$4"' _ "${AUTONOTE_CLI}" \
        "${WORK}/live-1.json" "${WORK}/q-1.json" "${first}"; code=$?
    [[ ${code} -eq 0 ]] || { fail "1 回目: exit ${code}（期待 0）"; return; }
    jq -e '.todos[0].side == "self" and .sent_question_ids == ["q1","q2"] and .asked_question_ids == ["q1"]
           and .questions.items[0].asked == true and .questions.items[0].asked_by == "model"
           and .questions.items[1].asked == false and .questions.items[1].text == "入館証の締め切り"' "${first}" >/dev/null \
        || { LAST_LOG="${first}"; fail "1 回目の形が違う: $(cat "${first}")"; return; }
    jq '.questions' "${first}" >"${WORK}/q-2.json"
    run_timeout 30 sh -c '"$1" dev live-summary "$2" --state "$3" --questions "$4" >"$5"' _ "${AUTONOTE_CLI}" \
        "${WORK}/live-2.json" "${first}" "${WORK}/q-2.json" "${second}"; code=$?
    [[ ${code} -eq 0 ]] || { fail "2 回目: exit ${code}（期待 0）"; return; }
    jq -e '.sent_question_ids == ["q2"] and .asked_question_ids == ["q2"]
           and ([.questions.items[] | select(.asked)] | length) == 2 and .consumed_through == 130' "${second}" >/dev/null \
        || { LAST_LOG="${second}"; fail "2 回目に聞けた項目が渡った、または形が違う: $(cat "${second}")"; return; }
    pass "1 回目 q1・q2 を渡して q1、2 回目 q2 だけを渡して q2"
}

# ---------------------------------------------------------------- 実行

# 10.x 共通: 架空の確定版の文字起こし（日英まじり、数字だけの行、一時停止の印）を ${WORK} に書く
write_dev_translate_input() {
    cat >"${WORK}/translate-in.json" <<'JSON'
{"engine":"fake","language":"auto","utterances":[
{"start":3,"end":6,"speaker":"other","text":"We moved about sixty percent of the tenants.","is_final":true},
{"start":7,"end":9,"speaker":"me","text":"残りも今月末までにいけそうですか。","is_final":true},
{"start":10,"end":11,"speaker":"unknown","text":"── 一時停止 ──","is_final":true},
{"start":12,"end":13,"speaker":"other","text":"60%","is_final":true},
{"start":14,"end":16,"speaker":"other","text":"Put me down. I'll take it.","is_final":true}]}
JSON
}

check_dev_translate_shape() {
    CURRENT="10.1 dev translate が偽の翻訳器で日英を自動で反転し、1 行の JSON を出す"
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    cli_or_skip || return
    write_dev_translate_input
    local out="${WORK}/translate-1.json" again="${WORK}/translate-1b.json"
    run_timeout 30 sh -c '"$1" dev translate "$2" >"$3"' _ "${AUTONOTE_CLI}" "${WORK}/translate-in.json" "${out}"; local code=$?
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    [[ "$(wc -l <"${out}" | tr -d ' ')" -eq 1 ]] || { LAST_LOG="${out}"; fail "出力が 1 行でない"; return; }
    jq -e '.target == "auto" and .model == "fake" and .utterances == 5 and .skipped == [2, 3]
           and ([.entries[].index] == [0, 1, 4])
           and .entries[0].source_lang == "en" and .entries[0].target_lang == "ja"
           and .entries[0].text == "JA: We moved about sixty percent of the tenants."
           and .entries[1].source_lang == "ja" and .entries[1].target_lang == "en"
           and .entries[1].text == "EN: 残りも今月末までにいけそうですか。"' "${out}" >/dev/null \
        || { LAST_LOG="${out}"; fail "形か言語の判定が違う: $(cat "${out}")"; return; }
    run_timeout 30 sh -c '"$1" dev translate "$2" >"$3"' _ "${AUTONOTE_CLI}" "${WORK}/translate-in.json" "${again}"
    cmp -s "${out}" "${again}" || { LAST_LOG="${again}"; fail "2 回目の出力が 1 回目と違う（決定的でない）"; return; }
    pass "訳 3 件（en→ja 2・ja→en 1）、数字だけの行と一時停止の印は訳さない、2 回とも同じ"
}

check_dev_translate_fixed_target() {
    CURRENT="10.2 dev translate --target ja は英語の行だけを訳す（日本語の行はそのまま）"
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    cli_or_skip || return
    [[ -s "${WORK}/translate-in.json" ]] || write_dev_translate_input
    local out="${WORK}/translate-2.json"
    run_timeout 30 sh -c '"$1" dev translate "$2" --target ja >"$3"' _ "${AUTONOTE_CLI}" "${WORK}/translate-in.json" "${out}"; local code=$?
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    jq -e '.target == "ja" and ([.entries[].index] == [0, 4]) and ([.entries[].target_lang] | unique == ["ja"])
           and .skipped == [1, 2, 3]' "${out}" >/dev/null \
        || { LAST_LOG="${out}"; fail "訳す先の固定が効いていない: $(cat "${out}")"; return; }
    run_timeout 10 "${AUTONOTE_CLI}" dev translate "${WORK}/translate-in.json" --target fr; code=$?
    [[ ${code} -eq 2 ]] || { fail "--target fr が exit ${code}（期待 2 = usage）"; return; }
    pass "訳 2 件（英語の行だけ）、--target fr は usage"
}

check_dev_translate_summaries() {
    CURRENT="10.5 dev translate --minutes --live-summary が要約を要約の言語の反対へ訳す（原文のファイルは書き換えない）"
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    cli_or_skip || return
    [[ -s "${WORK}/translate-in.json" ]] || write_dev_translate_input
    cat >"${WORK}/translate-minutes.json" <<'JSON'
{"schema_version":2,"title":"移行の定例","summary":["週末に六割を移した。"],"decisions":[{"text":"月末までに終える","t":"00:01:00"}],
"agenda":[],"next_actions":[{"text":"手順書を送る","owner":"佐藤","due":"2026-11-30","t":"00:02:00","priority":"high"}],
"suggested_terms":[],"attendees":[{"name":"佐藤","role":"PM"}],"key_points":[],"insights":[],"questions":[],"deadlines":[],
"follow_ups":[],"risks":[],"architecture_diagram":null}
JSON
    cat >"${WORK}/translate-live.json" <<'JSON'
{"now":"Migration status","decisions":["Finish by month end"],"todos":[{"text":"Send the runbook","owner":null,"side":"self"}],
"consumed_through":30}
JSON
    local before; before="$(shasum -a 256 "${WORK}/translate-minutes.json" "${WORK}/translate-live.json")"
    local out="${WORK}/translate-5.json" same="${WORK}/translate-5b.json"
    run_timeout 30 sh -c '"$1" dev translate "$2" --minutes "$3" --live-summary "$4" >"$5"' _ "${AUTONOTE_CLI}" \
        "${WORK}/translate-in.json" "${WORK}/translate-minutes.json" "${WORK}/translate-live.json" "${out}"; local code=$?
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    jq -e '.minutes.summary_lang == "ja" and .minutes.target_lang == "en"
           and ([.minutes.entries[].source] == ["週末に六割を移した。", "移行の定例", "月末までに終える", "手順書を送る"])
           and .minutes.entries[2].text == "EN: 月末までに終える"
           and ([.minutes.entries[].source] | index("佐藤") == null)
           and .live_summary.summary_lang == "en" and .live_summary.target_lang == "ja"
           and ([.live_summary.entries[].text] == ["JA: Migration status", "JA: Finish by month end", "JA: Send the runbook"])
           and ([.entries[].index] == [0, 1, 4])' "${out}" >/dev/null \
        || { LAST_LOG="${out}"; fail "要約の訳の形か向きが違う: $(cat "${out}")"; return; }
    [[ "$(shasum -a 256 "${WORK}/translate-minutes.json" "${WORK}/translate-live.json")" == "${before}" ]] \
        || { fail "原文の要約ファイルが書き換わった"; return; }
    run_timeout 30 sh -c '"$1" dev translate "$2" --target ja --minutes "$3" >"$4"' _ "${AUTONOTE_CLI}" \
        "${WORK}/translate-in.json" "${WORK}/translate-minutes.json" "${same}"; code=$?
    [[ ${code} -eq 0 ]] || { fail "--target ja が exit ${code}（期待 0）"; return; }
    jq -e '.minutes.entries == [] and .minutes.summary_lang == "ja" and (.minutes | has("target_lang") | not)' "${same}" >/dev/null \
        || { LAST_LOG="${same}"; fail "訳す先が要約の言語と同じなのに訳した: $(cat "${same}")"; return; }
    pass "議事録 ja→en 4 件（担当者名は訳さない）、ライブ要約 en→ja 3 件、--target ja の日本語の議事録は訳さない"
}

check_dev_translate_real_model() {
    CURRENT="10.3 dev translate --model で本物の PLaMo 3 Translate が訳す（モデルと翻訳エンジンがあるときだけ）"
    command -v jq >/dev/null 2>&1 || { skip "jq が無い"; return; }
    cli_or_skip || return
    local model="${E2E_PLAMO_MODEL:-${HOME}/Library/Caches/autonote-plamo-spike/models/pfnet/plamo-3-translate-0.8b-GGUF/plamo-3-translate-0.8b-Q4_K_M.gguf}"
    [[ -f "${model}" ]] || { skip "モデルが無い（E2E_PLAMO_MODEL で GGUF を指定する）"; return; }
    [[ -s "${WORK}/translate-in.json" ]] || write_dev_translate_input
    local out="${WORK}/translate-3.json"
    run_timeout 120 sh -c '"$1" dev translate "$2" --model "$3" >"$4"' _ "${AUTONOTE_CLI}" "${WORK}/translate-in.json" "${model}" "${out}"; local code=$?
    if [[ ${code} -ne 0 ]] && grep -q "翻訳エンジン" "${LAST_LOG}"; then skip "このビルドには翻訳エンジンが無い（--model は分かりやすいエラーで止まる）"; return; fi
    [[ ${code} -eq 0 ]] || { fail "exit ${code}（期待 0）"; return; }
    jq -e '([.entries[].index] == [0, 1, 4]) and (.entries[1].text | test("[A-Za-z]"))
           and (.entries[0].text | test("[ぁ-んァ-ン一-龥]"))' "${out}" >/dev/null \
        || { LAST_LOG="${out}"; fail "訳が期待の言語でない: $(cat "${out}")"; return; }
    pass "$(jq -r '.entries[0].text' "${out}")"
}

check_translation_default_off() {
    CURRENT="10.4 翻訳は既定オフで、起動しても翻訳モデルをダウンロードしない"
    app_or_skip || return
    local mode; mode="$(plutil -extract translation_mode raw -o - "${DATA}/settings.json" 2>/dev/null)"
    [[ -z "${mode}" || "${mode}" == "off" ]] || { LAST_LOG=""; fail "settings.json の translation_mode が「${mode}」（期待: なし か off）"; return; }
    local files; files="$(find "${DATA}/models/translation" -type f 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${files}" -eq 0 ]] || { LAST_LOG=""; fail "${DATA}/models/translation にファイルが ${files} 個（期待 0）"; return; }
    pass "translation_mode ${mode:-（未設定）}、models/translation は空"
}

# 16.x: 自動アップデート。scripts/update-e2e.sh（一時ディレクトリのアプリの写しと偽の配布サーバー）の各行をそのまま項目にする。
# 項目 7 のアプリとは別のデータ領域・別の写しで動き、/Applications のアプリには触れない
check_auto_update() {
    CURRENT="16. 自動アップデート（scripts/update-e2e.sh）"
    [[ -x "${APP}/Contents/MacOS/AutoNoteApp" ]] || { skip "build/AutoNote.app が無い"; return; }
    have_cert || { skip "署名証明書「${CERT_NAME}」が無い"; return; }
    have_gui || { skip "GUI が無い環境（CI か WindowServer なし）"; return; }
    # 2 回: 「AutoNote Dev」（この Mac では信頼済み）で 16.N、その場で作った信頼の無い証明書で 16u.N（利用者の Mac と同じ条件）
    local mode
    for mode in trusted untrusted; do
        CURRENT="16. 自動アップデート（scripts/update-e2e.sh、${mode}）"
        export E2E_UPDATE_IDENTITY="${mode}"
        run_timeout 600 "${ROOT}/scripts/update-e2e.sh" "${APP}"; local code=$?
        unset E2E_UPDATE_IDENTITY
        local lines; lines="$(grep -E '^(PASS|FAIL|SKIP)  ' "${LAST_LOG}")"
        [[ -n "${lines}" ]] || { fail "結果の行が無い（exit ${code}）"; continue; }
        local log="${LAST_LOG}" kind rest name reason
        while IFS= read -r line; do
            kind="${line%%  *}"; rest="${line#*  }"
            name="${rest%% — *}"; reason=""; [[ "${rest}" == *" — "* ]] && reason="${rest#* — }"
            CURRENT="${name}"; LAST_LOG="${log}"
            case "${kind}" in
                PASS) pass "${reason}" ;;
                SKIP) skip "${reason}" ;;
                *) LAST_LOG=""; fail "${reason}" ;;
            esac
        done <<<"${lines}"
        [[ ${code} -eq 124 ]] && { CURRENT="16. 自動アップデート（${mode}）"; LAST_LOG="${log}"; fail "600 秒で終わらない"; }
    done
    return 0
}

CHECKS=(
    check_identity_consistency
    check_swift_test
    check_build_app
    check_codesign_identity
    check_codesign_verify
    check_info_plist
    check_bundle_version
    check_cli
    check_cli_app_not_running
    check_app_launch
    check_first_run_output_folder
    check_first_run_no_download
    check_translation_default_off   # アプリが動いている間に見る（06.6 でアプリを止めるため）
    check_menu_no_folder_warning
    check_status_over_socket
    check_failure_message_compat
    check_bookmark_not_recording
    check_automation_run
    check_recording_main_thread
    check_live_summary_default_off
    check_merge_recordings
    check_automation_log_and_socket
    check_cer
    check_whisper
    check_results_doc
    check_fake_transcript
    check_claude_probe_files
    check_bt_verify_script
    check_render_fixture
    check_render_fixture_detects_diff
    check_dev_record
    check_dev_import
    check_dev_devices
    check_dev_devices_watch
    check_dev_auto_record_quit
    check_dev_engines
    check_dev_transcribe_dictation
    check_dev_transcribe_whisper
    check_dev_transcribe_whisper_live
    check_dev_transcribe_whisper_resampled
    check_batch_memory_flat
    check_dev_summarize
    check_dev_summarize_failure
    check_dev_summarize_minutes_out
    check_eval_unit_tests
    check_dev_live_summary_shape
    check_dev_live_summary_accumulates
    check_dev_live_summary_questions
    check_dev_translate_shape
    check_dev_translate_fixed_target
    check_dev_translate_summaries
    check_dev_translate_real_model
    check_auto_update
)

ensure_whisper_xcframework   # 失敗しても続ける（swift test などの項目が FAIL を出す）

START=${SECONDS}
for c in "${CHECKS[@]}"; do
    LAST_LOG=""
    "${c}"
done

echo "----"
echo "${N_PASS} passed, ${N_FAIL} failed, ${N_SKIP} skipped（$((SECONDS - START)) 秒）"
[[ "${N_FAIL}" -eq 0 ]]
