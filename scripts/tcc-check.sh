#!/usr/bin/env bash
# 計画 02 Task 1 の TCC まとめ確認。人の手が要らない手順をすべて自動で行い、結果を記録する。
#
# 使い方: scripts/tcc-check.sh <phase> [--reset]
#   audio-persist  システム音声録音の許可の持続（Task 1 Step 4）
#                  AudioCapture の許可（auth_value=2）が無ければ「初回」: tccutil reset → 起動 → 「システム音声を確認」
#                  → ダイアログの有無を記録して、利用者に許可を頼む。
#                  許可があれば「確認」: もう一度「システム音声を確認」→ TCC.db → 終了 → CFBundleVersion を 1 上げて
#                  再ビルド → 起動 → 「システム音声を確認」→ ダイアログが出ないこと・last_modified が変わらないことを記録。
#                  --reset を付けると許可があっても「初回」からやり直す。
#   audio-denied   許可なしの挙動（Step 5。利用者が許可をオフにして再起動した後に回す）
#   dictation      DictationTranscriber が音声認識の許可なしで動くか（Step 6）
#   bt-silence     BT 出力で無音時に IOProc が止まるか（Step 7。出力を Shokz にして 1 回、内蔵スピーカーにして 1 回）
#
# 記録先: docs/superpowers/research/2026-10-24-spike-raw/plan02-task1-tcc.log（追記。Bluetooth の UID は下 3 オクテットを伏せる）
# 許可ダイアログはこのスクリプトでは押さない。出ていれば記録して、利用者に頼む内容を最後に表示する。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}" || exit 2

PHASE="${1:-}"
RESET=0
[[ "${2:-}" == "--reset" ]] && RESET=1

BUNDLE_ID="com.yutaokoshi.autonote"
APP="${ROOT}/build/AutoNote.app"
OUT="${ROOT}/docs/superpowers/research/2026-10-24-spike-raw/plan02-task1-tcc.log"
DEVLOG="${HOME}/Library/Application Support/AutoNote/logs/dev-checks.log"
TCCDB="${HOME}/Library/Application Support/com.apple.TCC/TCC.db"
PLIST="${ROOT}/Resources/Info.plist"
DICTATION_FILE="/tmp/autonote-dictation.aiff"
ITEM_SYSTEM="システム音声を確認（15 秒）"
ITEM_DICTATION="Dictation を確認（/tmp/autonote-dictation.aiff）"
TODO=()
AFPLAY_PID=""

mask() { sed -E 's/([0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2})[-:][0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2}[-:][0-9A-Fa-f]{2}/\1-xx-xx-xx/g'; }
now() { date '+%Y-%m-%d %H:%M:%S'; }
rec() { printf '%s\n' "$*" | mask | tee -a "${OUT}"; }
logcmd() { "$@" 2>&1 | mask | tee -a "${OUT}"; }
header() { rec ""; rec "## [$(now)] $*"; }

cleanup() {
    stop_afplay
}
trap cleanup EXIT

start_afplay() {
    local sound="${1:-/System/Library/Sounds/Submarine.aiff}"
    ( while true; do afplay "${sound}"; done ) >/dev/null 2>&1 &
    AFPLAY_PID=$!
    rec "afplay loop started (${sound##*/})"
}

stop_afplay() {
    if [[ -n "${AFPLAY_PID}" ]]; then
        kill "${AFPLAY_PID}" 2>/dev/null
        wait "${AFPLAY_PID}" 2>/dev/null
        pkill -x afplay 2>/dev/null
        AFPLAY_PID=""
        rec "afplay loop stopped"
    fi
}

tcc_rows() {
    local label="$1"
    rec "### TCC.db (${label})"
    logcmd sqlite3 -readonly "${TCCDB}" \
        "select service,client,auth_value,auth_reason,datetime(last_modified,'unixepoch','localtime') from access where client like '${BUNDLE_ID}%' order by service"
}

# 指定サービスの last_modified（無ければ空）
tcc_value() {
    sqlite3 -readonly "${TCCDB}" \
        "select auth_value || '|' || datetime(last_modified,'unixepoch','localtime') from access where client='${BUNDLE_ID}' and service='$1'" 2>/dev/null
}

screen_locked() {
    local locked
    locked="$(ioreg -n Root -d1 | grep -o '"CGSSessionScreenIsLocked"=[A-Za-z]*' | cut -d= -f2)"
    echo "${locked:-No}"
}
screen_state() { rec "screen locked: $(screen_locked)（ロック中は許可ダイアログが見えず、System Events の窓一覧も空になる）"; }

app_running() { pgrep -x AutoNoteApp >/dev/null; }

app_open() {
    open "${APP}" || { rec "open failed"; return 1; }
    local i
    for i in $(seq 1 50); do app_running && break; sleep 0.2; done
    sleep 2   # メニューバー項目ができるまで待つ
    if app_running; then rec "AutoNoteApp running (pid $(pgrep -x AutoNoteApp | tr '\n' ' '))"; else rec "AutoNoteApp not running"; return 1; fi
}

app_quit() {
    app_running || return 0
    pkill -x AutoNoteApp   # Apple Events の quit は応答待ちで 2 分止まることがある（実測）
    local i
    for i in $(seq 1 25); do app_running || break; sleep 0.2; done
    app_running && pkill -9 -x AutoNoteApp
    sleep 1
    rec "AutoNoteApp quit"
}

# 「開発」サブメニューの項目を押す（menu bar 2 = ステータス項目のメニューバー）
click_dev() {
    local item="$1" r
    r="$(osascript 2>&1 <<EOF
tell application "System Events" to tell process "AutoNoteApp"
    click menu bar item 1 of menu bar 2
    delay 0.5
    click menu item "開発" of menu 1 of menu bar item 1 of menu bar 2
    delay 0.5
    click menu item "${item}" of menu 1 of menu item "開発" of menu 1 of menu bar item 1 of menu bar 2
end tell
EOF
)"
    rec "click 開発 > ${item}: ${r}"
}

# 窓を持つプロセスの一覧（許可ダイアログが出たかを見る。押しはしない）。画面ロック中は空になる。
window_snapshot() {
    osascript 2>/dev/null <<'EOF'
tell application "System Events"
    set out to ""
    repeat with p in (every process)
        try
            set c to count of windows of p
            if c > 0 then set out to out & (name of p) & ": " & ((name of every window of p) as text) & linefeed
        end try
    end repeat
    return out
end tell
EOF
}

# tccd / coreaudiod のログで、指定時刻以降のプロンプト（AUTHREQ_PROMPTING）・問い合わせ・tap の出来事を拾う
tcc_log_since() {
    local since="$1" service="$2"
    log show --start "${since}" --style compact \
        --predicate 'process == "tccd" OR process == "coreaudiod"' 2>/dev/null \
        | grep -E "AUTHREQ_PROMPTING.*${service}|AUTHREQ_CTX.*service=${service}|not granted|autonote\.tap|Client is not granted" \
        | cut -c1-400 | tail -n 60 | mask
}

devlog_lines() { [[ -f "${DEVLOG}" ]] && wc -l < "${DEVLOG}" | tr -d ' ' || echo 0; }

# dev-checks.log に pattern が現れるまで待つ（from 行より後）
wait_devlog() {
    local from="$1" pattern="$2" timeout="$3" i
    for i in $(seq 1 "${timeout}"); do
        if [[ -f "${DEVLOG}" ]] && tail -n "+$((from + 1))" "${DEVLOG}" | grep -qE "${pattern}"; then return 0; fi
        sleep 1
    done
    return 1
}

devlog_since() {
    local from="$1"
    rec "### dev-checks.log"
    [[ -f "${DEVLOG}" ]] && tail -n "+$((from + 1))" "${DEVLOG}" | mask | tee -a "${OUT}"
}

# 「システム音声を確認」を 1 回押して、ダイアログの有無と結果を記録する。DIALOG に yes/no/unknown を入れる
DIALOG=""
run_system_check() {
    local label="$1" before after from since
    header "${PHASE}: ${label}"
    screen_state
    before="$(window_snapshot)"
    from="$(devlog_lines)"
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    click_dev "${ITEM_SYSTEM}"
    sleep 4
    after="$(window_snapshot)"
    local newwin
    newwin="$(diff <(printf '%s\n' "${before}") <(printf '%s\n' "${after}") | grep '^>' | sed 's/^> //')"
    rec "### windows appeared after click (System Events)"
    rec "${newwin:-（なし）}"
    # 許可の問い合わせが保留中だと AudioDeviceStart と破棄がそれぞれ約 90 秒止まる（実測）ので長めに待つ
    if ! wait_devlog "${from}" 'system end' 300; then rec "dev-checks.log: 'system end' が 300 秒以内に出なかった"; fi
    devlog_since "${from}"
    local tl
    tl="$(tcc_log_since "${since}" kTCCServiceAudioCapture)"
    rec "### log show (tccd/coreaudiod since ${since}, filtered)"
    rec "${tl:-（該当なし）}"
    if grep -qE 'AUTHREQ_PROMPTING.*kTCCServiceAudioCapture' <<<"${tl}" || [[ -n "${newwin}" ]]; then
        DIALOG="yes"
    elif [[ "$(screen_locked)" == "Yes" ]]; then
        DIALOG="unknown"
    else
        DIALOG="no"
    fi
    rec "dialog shown: ${DIALOG}"
}

bump_and_rebuild() {
    local v next
    v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST}")"
    next=$((v + 1))
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${next}" "${PLIST}"
    rec "CFBundleVersion ${v} -> ${next}"
    if scripts/build-app.sh >/dev/null 2>&1; then rec "build-app exit 0"; else rec "build-app FAILED"; return 1; fi
    codesign -dv "${APP}" 2>&1 | grep -E '^Identifier|^CDHash' | mask | tee -a "${OUT}"
}

phase_audio_persist() {
    local granted
    granted="$(tcc_value kTCCServiceAudioCapture)"
    if [[ "${RESET}" -eq 1 || "${granted%%|*}" != "2" ]]; then
        header "audio-persist: 初回（AudioCapture=${granted:-none}）"
        tcc_rows before
        app_quit
        logcmd tccutil reset AudioCapture "${BUNDLE_ID}"
        tcc_rows "after tccutil reset"
        start_afplay
        app_open || return 1
        run_system_check "1 回目（許可前）"
        tcc_rows "after 1st check"
        stop_afplay
        TODO+=("「システム オーディオ録音」の許可ダイアログで AutoNote を許可する（ダイアログが無ければ システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオ録音 で AutoNote の「システムオーディオ録音のみ」をオン）。画面ロック中なら解除してから。")
        TODO+=("許可したら AutoNote は終了せずに: scripts/tcc-check.sh audio-persist")
        return 0
    fi
    header "audio-persist: 確認（AudioCapture=${granted}）"
    start_afplay
    app_running || app_open || return 1
    run_system_check "許可後 2 回目"
    tcc_rows "Step 4.4（許可後）"
    local before_mod="${granted#*|}"
    app_quit
    bump_and_rebuild || return 1
    app_open || return 1
    run_system_check "CFBundleVersion を上げて再ビルド後"
    local after
    after="$(tcc_value kTCCServiceAudioCapture)"
    tcc_rows "Step 4.5（再ビルド後）"
    stop_afplay
    header "audio-persist: まとめ"
    rec "AudioCapture before rebuild: ${granted} / after: ${after:-none}"
    if [[ "${after#*|}" == "${before_mod}" ]]; then rec "last_modified unchanged: yes"; else rec "last_modified unchanged: no"; fi
    rec "dialog after rebuild: ${DIALOG}"
}

phase_audio_denied() {
    header "audio-denied: 許可なし（再起動後）"
    rec "uptime: $(uptime)"
    tcc_rows before
    local v
    v="$(tcc_value kTCCServiceAudioCapture)"
    if [[ "${v%%|*}" != "0" ]]; then
        rec "AudioCapture が auth_value=0 ではない（${v:-none}）"
        TODO+=("システム設定 > プライバシーとセキュリティ > 画面とシステムオーディオ録音 で AutoNote の「システムオーディオ録音のみ」をオフ → Mac を再起動 → scripts/tcc-check.sh audio-denied")
        return 0
    fi
    app_quit
    start_afplay
    app_open || return 1
    run_system_check "許可なしで「システム音声を確認」"
    stop_afplay
    header "audio-denied: log show --last 3m (coreaudiod/tccd, tap|AudioCapture)"
    log show --last 3m --predicate 'process == "coreaudiod" OR process == "tccd"' 2>/dev/null \
        | grep -iE 'tap|AudioCapture' | tail -n 80 | mask | tee -a "${OUT}"
    tcc_rows after
    TODO+=("システム設定で AutoNote の「システムオーディオ録音のみ」をオンに戻す")
}

phase_dictation() {
    header "dictation: 音声認識の許可なしで DictationTranscriber"
    screen_state
    tcc_rows before
    logcmd tccutil reset SpeechRecognition "${BUNDLE_ID}"
    say -v Kyoko -o "${DICTATION_FILE}" "本日の定例会議を始めます。議題は三つあります。" && rec "say -> ${DICTATION_FILE} ($(stat -f %z "${DICTATION_FILE}") bytes)"
    app_running || app_open || return 1
    local before after from since newwin tl
    before="$(window_snapshot)"
    from="$(devlog_lines)"
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    click_dev "${ITEM_DICTATION}"
    sleep 4
    after="$(window_snapshot)"
    newwin="$(diff <(printf '%s\n' "${before}") <(printf '%s\n' "${after}") | grep '^>' | sed 's/^> //')"
    rec "### windows appeared after click (System Events)"
    rec "${newwin:-（なし）}"
    wait_devlog "${from}" 'dictation (ok|error)' 180 || rec "dev-checks.log: dictation の結果が 180 秒以内に出なかった"
    devlog_since "${from}"
    tl="$(tcc_log_since "${since}" kTCCServiceSpeechRecognition)"
    rec "### log show (tccd since ${since}, filtered)"
    rec "${tl:-（該当なし）}"
    tcc_rows after
    local sr
    sr="$(tcc_value kTCCServiceSpeechRecognition)"
    rec "kTCCServiceSpeechRecognition row: ${sr:-none}"
    if grep -qE 'AUTHREQ_PROMPTING.*kTCCServiceSpeechRecognition' <<<"${tl}" || [[ -n "${newwin}" ]]; then
        rec "dialog shown: yes"
        TODO+=("音声認識の許可ダイアログが出ている。押さずに内容を確認し（許可が要るという結果になる）、結果を Lead に伝える")
    else
        rec "dialog shown: no"
    fi
}

phase_bt_silence() {
    header "bt-silence: 無音時の IOProc（出力デバイス別）"
    local dev
    dev="$(system_profiler SPAudioDataType 2>/dev/null | awk '/^        [^ ].*:$/{name=$0} /Default Output Device: Yes/{gsub(/^ +|:$/,"",name); print name}')"
    rec "default output device: ${dev:-unknown}"
    app_running || app_open || return 1
    screen_state
    local from
    from="$(devlog_lines)"
    click_dev "${ITEM_SYSTEM}"
    ( sleep 5; afplay /System/Library/Sounds/Glass.aiff; sleep 5; afplay /System/Library/Sounds/Glass.aiff ) &
    local snd=$!
    rec "sound plan: +5 s Glass, +10 s Glass (relative to click)"
    wait "${snd}"
    wait_devlog "${from}" 'system end' 300 || rec "dev-checks.log: 'system end' が 300 秒以内に出なかった"
    devlog_since "${from}"
    TODO+=("Shokz（OpenRun Pro 2）と内蔵スピーカーの両方で 1 回ずつ回す: 出力を切り替えて scripts/tcc-check.sh bt-silence（今回の出力: ${dev:-unknown}）")
}

case "${PHASE}" in audio-persist|audio-denied|dictation|bt-silence) ;; *) sed -n '2,18p' "$0"; exit 2 ;; esac
[[ -f "${OUT}" ]] || printf '# 計画 02 Task 1 の TCC 確認（scripts/tcc-check.sh の出力。Bluetooth の UID は下 3 オクテットを伏せる）\n' > "${OUT}"
rec ""
rec "# ===== [$(now)] tcc-check.sh ${PHASE} $(sw_vers -productVersion) $(uname -m) ====="

case "${PHASE}" in
    audio-persist) phase_audio_persist ;;
    audio-denied) phase_audio_denied ;;
    dictation) phase_dictation ;;
    bt-silence) phase_bt_silence ;;
    *) sed -n '2,17p' "$0"; exit 2 ;;
esac

echo
if [[ ${#TODO[@]} -gt 0 ]]; then
    echo "=== 利用者の手で行うこと（終わったら上の phase を再実行） ==="
    for t in "${TODO[@]}"; do echo "- ${t}"; done
    { echo "### 利用者待ち"; for t in "${TODO[@]}"; do echo "- ${t}"; done; } >> "${OUT}"
else
    echo "=== ${PHASE}: 利用者の手は不要。結果は ${OUT#"${ROOT}/"} ==="
fi
