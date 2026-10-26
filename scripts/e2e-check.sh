#!/usr/bin/env bash
# AutoNote の E2E 動作確認。リポジトリの成果物が「実際に動く」ことを人の手なしで確かめる。
#
# 使い方: scripts/e2e-check.sh [--quick] [--verbose]
#   --quick     時間のかかる項目（swift test / build-app / Spikes build）を飛ばす（SKIP と表示）
#   --verbose   各コマンドの出力をそのまま見せる（既定は FAIL のときだけ末尾 20 行）
# 環境変数（FAIL 検出の確認用。副作用なしで期待値だけを変える）:
#   E2E_EXPECT_VERSION   autonote --version の期待値（既定: Sources/AutoNoteCore/AutoNoteVersion.swift の値）
#   E2E_MENUBAR_PROCESS  項目 7b で osascript が見るプロセス名（既定: AutoNoteApp）
#   AUTONOTE_CLI         項目 01.x が使う autonote の場所（既定: .build/debug/autonote）
#   E2E_MENUBAR_INDEX    項目 7b で見る menu bar の番号（既定: 2 = ステータス項目のメニューバー）
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
        -h|--help) sed -n "2,17p" "$0"; exit 0 ;;
        *) echo "不明な引数: ${arg}（使えるのは --quick と --verbose）" >&2; exit 2 ;;
    esac
done

APP="${ROOT}/build/AutoNote.app"
CERT_NAME="AutoNote Dev"
BUNDLE_ID="com.yutaokoshi.autonote"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/autonote-e2e.XXXXXX")"
APP_PID=""
cleanup() {
    if [[ -n "${APP_PID}" ]]; then kill "${APP_PID}" 2>/dev/null; wait "${APP_PID}" 2>/dev/null; fi
    rm -rf "${WORK}"
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

have_cert() { security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${CERT_NAME}\""; }
have_gui() { [[ -z "${CI:-}" ]] && pgrep -x WindowServer >/dev/null 2>&1; }

# 共通の補助（計画 01 が足し、後の計画の項目も使う。overview §7）
AUTONOTE_CLI="${AUTONOTE_CLI:-${ROOT}/.build/debug/autonote}"   # 環境変数で差し替え可
AUTONOTE_CLI_BUILT=0
need_autonote_cli() {   # 0: 使える / 1: 無い（呼び手が skip）/ 2: ビルド失敗（呼び手が fail）。--quick でなければ最初の 1 回だけ swift build
    if [[ "${QUICK}" -eq 0 && "${AUTONOTE_CLI_BUILT}" -eq 0 ]]; then run swift build --product autonote || return 2; AUTONOTE_CLI_BUILT=1; fi
    [[ -x "${AUTONOTE_CLI}" ]] || return 1
}
cli_or_skip() {   # 項目の先頭で呼ぶ。使えなければ skip / fail を出して 1 を返す
    need_autonote_cli; case $? in 0) return 0 ;; 1) skip "autonote が無い（swift build で作る）" ;; *) fail "swift build --product autonote が失敗" ;; esac; return 1
}

# ---------------------------------------------------------------- 確認項目

check_swift_test() {
    CURRENT="1. swift test"
    [[ "${QUICK}" -eq 1 ]] && { skip "--quick"; return; }
    if run swift test; then pass; else fail "swift test が失敗"; fi
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
    "${bin}" >"${WORK}/app.log" 2>&1 &
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
    # メニューバー項目の名前を System Events で読む（アクセシビリティ権限が要る）。
    # 権限エラーのときだけ SKIP。それ以外の失敗（menu bar が無い、時間切れ等）と waveform が無いのは FAIL。
    local proc="${E2E_MENUBAR_PROCESS:-AutoNoteApp}" idx="${E2E_MENUBAR_INDEX:-2}"
    local names="" result="" n
    for n in 1 2 3 4 5; do
        if run_timeout 10 osascript -e "tell application \"System Events\" to tell process \"${proc}\" to get name of every menu bar item of menu bar ${idx}"; then
            names="$(cat "${LAST_LOG}")"
            if [[ "${names}" == *waveform* ]]; then result=pass; break; fi
            result="no-waveform"
        # -1719 は「インデックスが正しくない」（menu bar が無い）にも使われるので、コード単体では判定せず文言で見る
        elif grep -Eqi 'assistive|補助アクセス|-25211|-1743|Not authorized to send Apple events' "${LAST_LOG}"; then
            result=permission; break
        else
            result=error
        fi
        sleep 1   # 起動直後はメニューバー項目がまだ無いことがあるので、権限エラー以外は再試行する
    done
    kill "${APP_PID}" 2>/dev/null; wait "${APP_PID}" 2>/dev/null; APP_PID=""
    pass "生存確認"
    CURRENT="7b. メニューバー項目 waveform（process ${proc} / menu bar ${idx}）"
    case "${result}" in
        pass) pass "「${names}」" ;;
        permission) skip "アクセシビリティ（または Apple Events）の権限が無い: $(tail -n 1 "${LAST_LOG}")" ;;
        no-waveform) LAST_LOG=""; fail "メニューバー項目「${names}」に waveform が無い" ;;
        *) fail "osascript が失敗（5 回試行）" ;;
    esac
}

check_spikes_build() {
    CURRENT="8. Spikes を swift build"
    [[ -d Spikes ]] || { skip "Spikes/ が無い"; return; }
    [[ "${QUICK}" -eq 1 ]] && { skip "--quick"; return; }
    if run swift build --package-path Spikes; then pass; else fail "Spikes のビルドが失敗"; fi
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
    if ! run jq -e '(.required | sort) == (["agenda","decisions","next_actions","suggested_terms","summary","title"]) and .additionalProperties == false and .properties.title.maxLength == 20 and .properties.summary.minItems == 3 and .properties.summary.maxItems == 3' scripts/minutes-schema.json; then
        fail "minutes-schema.json が JSON でない、または必須キー・制約が違う"; return
    fi
    if ! run bash -n scripts/probe-claude.sh; then fail "probe-claude.sh に構文エラー"; return; fi
    LAST_LOG=""; pass "（claude の実呼び出しは費用がかかるので E2E では行わない）"
}

check_device_probe() {
    CURRENT="14. Spikes の DeviceProbe が起動時の一覧 JSON を出し SIGINT で終わる"
    local bin=Spikes/.build/debug/DeviceProbe
    [[ -x "${bin}" ]] || { skip "${bin} が無い（swift build --package-path Spikes を先に）"; return; }
    new_log
    "${bin}" >"${LAST_LOG}" 2>&1 &
    local pid=$! i
    # 起動時の present 行（入力のある機器。内蔵マイクがあれば必ず 1 行）を最大 5 秒待つ
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
    if [[ ${code} -ne 0 ]]; then fail "SIGINT 後の終了コードが ${code}（期待 0）"; return; fi
    pass "present ${present} 行、exit 0"
}

check_apple_speech_probe() {
    CURRENT="15. Spikes の AppleSpeechProbe --engine transcriber が isAvailable を出す"
    local bin=Spikes/.build/debug/AppleSpeechProbe
    [[ -x "${bin}" ]] || { skip "${bin} が無い（swift build --package-path Spikes を先に）"; return; }
    # 機材・許可は不要（SpeechTranscriber / DictationTranscriber の静的な問い合わせだけ）
    if ! run_timeout 30 "${bin}" --engine transcriber --locale ja-JP; then fail "exit 0 で終わらない"; return; fi
    local line
    line="$(grep -m1 '^SpeechTranscriber.isAvailable: ' "${LAST_LOG}")"
    [[ -n "${line}" ]] || { fail "isAvailable の行が無い"; return; }
    grep -q '^DictationTranscriber.supportedLocales: ' "${LAST_LOG}" || { fail "DictationTranscriber.supportedLocales の行が無い"; return; }
    pass "${line}、$(grep -m1 '^DictationTranscriber.supportedLocales: ' "${LAST_LOG}")"
}

check_apple_speech_probe_guard() {
    CURRENT="15b. AppleSpeechProbe --engine transcriber --live / --file は未実装として exit 2"
    local bin=Spikes/.build/debug/AppleSpeechProbe
    [[ -x "${bin}" ]] || { skip "${bin} が無い（swift build --package-path Spikes を先に）"; return; }
    local args code
    for args in "--live" "--file /dev/null"; do
        # shellcheck disable=SC2086
        run_timeout 30 "${bin}" --engine transcriber --locale ja-JP ${args}; code=$?
        if [[ ${code} -ne 2 ]]; then fail "${args}: exit ${code}（期待 2）"; return; fi
        grep -q '未実装' "${LAST_LOG}" || { fail "${args}: stderr に「未実装」が無い"; return; }
    done
    pass "--live / --file とも exit 2"
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

# ---------------------------------------------------------------- 実行

CHECKS=(
    check_swift_test
    check_build_app
    check_codesign_identity
    check_codesign_verify
    check_info_plist
    check_bundle_version
    check_cli
    check_app_launch
    check_spikes_build
    check_cer
    check_whisper
    check_results_doc
    check_fake_transcript
    check_claude_probe_files
    check_device_probe
    check_apple_speech_probe
    check_apple_speech_probe_guard
    check_render_fixture
    check_render_fixture_detects_diff
)

START=${SECONDS}
for c in "${CHECKS[@]}"; do
    LAST_LOG=""
    "${c}"
done

echo "----"
echo "${N_PASS} passed, ${N_FAIL} failed, ${N_SKIP} skipped（$((SECONDS - START)) 秒）"
[[ "${N_FAIL}" -eq 0 ]]
