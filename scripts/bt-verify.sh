#!/usr/bin/env bash
# Bluetooth ヘッドセットを接続した直後の自動録音で「マイクが無音のまま」になる不具合の修正を、実機で確かめる。
# 修正前のビルドと修正後のビルドを、同じ手順（アプリ常駐 → Chrome のタブで音を再生 → ヘッドセットを接続 → 自動録音）で比べる。
#
# 使い方: scripts/bt-verify.sh [--dry-run] [--seconds N] [--only C0,C1,C2,C3,R] [--no-real] [--out DIR]
#                              [--before-app PATH] [--after-app PATH] [--build-before] [--bt-name 名前の一部]
#   --dry-run       音・マイク・アプリ・Chrome を使わない。前提の確認と手順の表示だけ（端末なしでも動く）
#   --seconds N     1 条件の録音の長さ（既定 30、10 以上）
#   --only LIST     条件を絞る（C0,C1,C2,C3,R のカンマ区切り）
#   --no-real       最後の任意条件 R（実際の会議アプリ）を聞かずに飛ばす
#   --before-app    修正前のアプリ（既定: この Git リポジトリの他の worktree のうち HEAD が origin/main のものの
#                   build/AutoNote.app。修正を含まないことも確かめる）
#   --after-app     修正後のアプリ（既定: この worktree の build/AutoNote.app。scripts/build-app.sh release で作る）
#   --build-before  修正前のアプリが見つからないとき、origin/main を一時の worktree（結果フォルダの中）でビルドする
#   --bt-name       ヘッドセットの判定を名前でも絞る（既定は「既定の出力の transport が bluetooth」だけで判定）
# 条件:
#   C0  アプリなし。Chrome のタブで音を再生中にヘッドセットを接続（対照。接続後も鳴り続けるか）
#   C1  修正前のアプリを常駐 → Chrome タブ再生中 → 接続 → 約 5 秒後に自動録音
#   C2  修正後のアプリで C1 と同じ
#   C3  修正後のアプリ。接続後に「サウンド › 入力」を内蔵マイクにして手動で録音開始（既定入力 = 内蔵マイクで録る）
#   R   任意。修正後のアプリを常駐させたまま、実際の会議アプリ（Meet か Zoom）に 1 人で入り、別の音を流して接続
# 記録: <OUT>/summary.md の 1 つの表（マイク・システム音声の RMS とゼロ秒、manifest の audio_health、聞こえたか、
#       ログの「stopping the engine」「mic rebuild」の件数、既定の入出力の変化）。
# 触れないもの: /Applications のアプリ（起動も終了もしない）、利用者の設定・録音・Vault（devices.json・settings.json・
#   モデルは読むだけ。一時のデータ領域にコピー/リンクする）、許可（TCC）、サウンドの設定（切替は利用者の手作業）。
#   要約（claude）は動かさない（claude_path を /usr/bin/false、ライブ要約は無効）。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECS=30
DRY=0
OUT=""
BT_NAME=""
ONLY=""
REAL=1
BEFORE_APP=""
AFTER_APP="${ROOT}/build/AutoNote.app"
BUILD_BEFORE=0
PORT=8766
FIX_MARK="mic rebuild #"    # 修正後のバイナリにだけある文字列（MicrophoneSource のログ）
SUBSYSTEM="com.yutaokoshi.autonote"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --seconds) SECS="${2:-}"; shift 2 ;;
        --out) OUT="${2:-}"; shift 2 ;;
        --bt-name) BT_NAME="${2:-}"; shift 2 ;;
        --only) ONLY="${2:-}"; shift 2 ;;
        --no-real) REAL=0; shift ;;
        --before-app) BEFORE_APP="${2:-}"; shift 2 ;;
        --after-app) AFTER_APP="${2:-}"; shift 2 ;;
        --build-before) BUILD_BEFORE=1; shift ;;
        -h|--help) sed -n 2,26p "$0"; exit 0 ;;
        *) echo "不明なオプション: $1（--help で使い方）" >&2; exit 2 ;;
    esac
done
[[ "${SECS}" =~ ^[0-9]+$ ]] && (( SECS >= 10 )) || { echo "--seconds は 10 以上の整数にしてください" >&2; exit 2; }
if [[ -n "${ONLY}" ]]; then
    for c in ${ONLY//,/ }; do [[ "${c}" =~ ^(C0|C1|C2|C3|R)$ ]] || { echo "--only に使えるのは C0,C1,C2,C3,R です（${c}）" >&2; exit 2; }; done
fi

if [[ ${DRY} == 0 ]] && ! { : < /dev/tty; } 2>/dev/null; then
    cat >&2 <<EOM
このスクリプトは質問に答え、ヘッドセットをつないだり切ったりしながら進めるので、対話できる端末が要ります（いまは端末がありません）。
ターミナル（Terminal.app など）で直接実行してください:

    cd ${ROOT} && scripts/bt-verify.sh

前提だけを見るなら --dry-run は端末なしでも動きます。
EOM
    exit 2
fi

OUT="${OUT:-${TMPDIR:-/tmp}/bt-verify-$(date +%Y%m%d-%H%M%S)}"
WEB="${OUT}/web"
PROBE="${OUT}/bt-verify-probe"
TSV="${OUT}/conditions.tsv"
mkdir -p "${OUT}" "${WEB}"
: > "${TSV}"
SERVER_PID=""; STREAM_PID=""; RUNNING_APP_BIN=""

say_() { printf '%s\n' "$*"; }
hr() { printf '\n==== %s ====\n' "$*"; }
want() { [[ -z "${ONLY}" ]] || [[ ",${ONLY}," == *",$1,"* ]]; }
now() { date '+%Y-%m-%d %H:%M:%S'; }
epoch() { date +%s; }
ask() { if [[ ${DRY} == 1 ]]; then REPLY="(dry-run)"; return; fi; read -r -p "$1 " REPLY < /dev/tty || REPLY=""; }

quit_app() {
    [[ -n "${RUNNING_APP_BIN}" ]] || return 0
    pkill -f "${RUNNING_APP_BIN}" 2>/dev/null
    local n=0; while pgrep -f "${RUNNING_APP_BIN}" >/dev/null && (( n < 20 )); do sleep 0.5; n=$((n + 1)); done
    RUNNING_APP_BIN=""
}
cleanup() {
    [[ -n "${SERVER_PID}" ]] && kill "${SERVER_PID}" 2>/dev/null
    [[ -n "${STREAM_PID}" ]] && kill "${STREAM_PID}" 2>/dev/null
    quit_app
    return 0
}
trap cleanup EXIT INT TERM

# ---- プローブ（既定の入出力の状態を読むだけ） ----
command -v swiftc >/dev/null || { say_ "swiftc が見つかりません（Command Line Tools が要ります）"; exit 2; }
if ! swiftc -O -suppress-warnings "${ROOT}/scripts/bt-verify-probe.swift" -o "${PROBE}" 2>"${OUT}/compile.log"; then
    say_ "プローブのコンパイルに失敗しました（${OUT}/compile.log）。SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk を付けて再実行してください"
    exit 2
fi
devjson() { "${PROBE}" 2>/dev/null || echo '{}'; }
field() { devjson | python3 -I -c 'import json,sys; d=json.load(sys.stdin).get(sys.argv[1]) or {}; v=d.get(sys.argv[2], ""); print(v)' "$1" "$2"; }
snap() { devjson > "$1"; }
describe() {
    devjson | python3 -I -c '
import json,sys
d=json.load(sys.stdin)
for k,l in (("default_output","既定の出力"),("default_input","既定の入力")):
    x=d.get(k)
    if not x: print("  %s: なし" % l); continue
    ch = x.get("out_channels" if k=="default_output" else "in_channels","?")
    print("  %s: %s / %s Hz / %sch / %s" % (l, x.get("transport","?"), int(x.get("sample_rate",0)), ch, "動作中" if x.get("running_somewhere") else "停止"))'
}
bt_is_up() {   # 既定の出力がヘッドセットか
    local t n; t="$(field default_output transport)"; n="$(field default_output name)"
    [[ "${t}" == bluetooth ]] || return 1
    [[ -z "${BT_NAME}" || "${n}" == *"${BT_NAME}"* ]]
}
wait_bt() {   # wait_bt up|down（最大 120 秒）
    local n=0
    while true; do
        if [[ "$1" == up ]]; then bt_is_up && return 0; else bt_is_up || { [[ -n "$(field default_output transport)" ]] && return 0; }; fi
        sleep 0.3; n=$((n + 1))
        (( n > 400 )) && { say_ "  120 秒待っても変わりません。この条件を飛ばします"; return 1; }
    done
}
wait_input_builtin() {   # 既定の入力が内蔵マイクになるまで（最大 25 秒）
    local n=0
    until [[ "$(field default_input transport)" == builtin ]]; do
        sleep 0.3; n=$((n + 1)); (( n > 83 )) && return 1
    done
}
chrome_audio() { pmset -g assertions 2>/dev/null | grep -iE 'Chrome' | grep -icE 'audio|coreaudio'; }
has_fix() { [[ -x "$1/Contents/MacOS/AutoNoteApp" ]] && grep -qaF "${FIX_MARK}" "$1/Contents/MacOS/AutoNoteApp"; }
app_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null; }

# 修正前のアプリ: 指定がなければ、同じリポジトリの他の worktree のうち HEAD が origin/main のものの build/AutoNote.app
# （修正を含まないことも確かめる）。無ければ --build-before で作ったもの。
find_before_app() {
    [[ -n "${BEFORE_APP}" ]] && return 0
    local wt main
    main="$(git -C "${ROOT}" rev-parse origin/main 2>/dev/null)"
    while IFS= read -r wt; do
        [[ "${wt}" == "${ROOT}" || -z "${main}" ]] && continue
        [[ "$(git -C "${wt}" rev-parse HEAD 2>/dev/null)" == "${main}" ]] || continue
        if [[ -d "${wt}/build/AutoNote.app" ]] && ! has_fix "${wt}/build/AutoNote.app"; then BEFORE_APP="${wt}/build/AutoNote.app"; return 0; fi
    done < <(git -C "${ROOT}" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
    [[ -d "${OUT}/before-src/build/AutoNote.app" ]] && BEFORE_APP="${OUT}/before-src/build/AutoNote.app"
    return 0
}
build_before() {
    local src="${OUT}/before-src"
    say_ "  修正前（origin/main）を ${src} でビルドします（数分）…"
    git -C "${ROOT}" fetch -q origin main 2>/dev/null || true
    git -C "${ROOT}" worktree add -q --detach "${src}" origin/main || { say_ "  ✗ worktree を作れませんでした"; return 1; }
    mkdir -p "${src}/tools"
    cp -R "${ROOT}/tools/whisper.xcframework" "${src}/tools/" || { say_ "  ✗ tools/whisper.xcframework をコピーできませんでした"; return 1; }
    ( cd "${src}" && SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}" scripts/build-app.sh release ) > "${OUT}/build-before.log" 2>&1 \
        || { say_ "  ✗ ビルドに失敗しました（${OUT}/build-before.log）"; return 1; }
    BEFORE_APP="${src}/build/AutoNote.app"
    say_ "  ✓ ビルドしました（後で消すなら: git -C '${ROOT}' worktree remove --force '${src}'）"
}

# ---- 前提の確認 ----
PROBLEMS=()
problem() { PROBLEMS+=("$1"); }
NEED_APPS=0; { want C1 || want C2 || want C3 || want R; } && NEED_APPS=1
hr "前提の確認"
describe
if bt_is_up; then say_ "  ✓ 既定の出力は Bluetooth のヘッドセット"
else say_ "  ✗ 既定の出力が Bluetooth ではありません"; problem "ヘッドセットを接続し、システム設定 › サウンド › 出力 でそれを選ぶ"; fi
if pgrep -x AutoNoteApp >/dev/null; then say_ "  ✗ AutoNote のアプリが動いています"; problem "動いている AutoNote（メニューバー）を終了する。このスクリプトは build 版を一時のデータ領域で別に起動します"
else say_ "  ✓ AutoNote アプリは動いていません"; fi
for p in "zoom.us" "Microsoft Teams" "Slack" "FaceTime" "Webex" "Discord"; do
    pgrep -ix "${p}" >/dev/null && { say_ "  ✗ ${p} が動いています"; problem "${p} を終了する（Cmd+Q）。任意の条件 R だけ、あとで Zoom を使えます"; }
done
[[ -d "/Applications/Google Chrome.app" ]] && say_ "  ✓ Google Chrome あり" || { say_ "  ✗ Google Chrome がありません"; problem "Google Chrome をインストールする（音源に使う）"; }
if (( NEED_APPS )); then
    if { want C2 || want C3 || want R; }; then
        if [[ -x "${AFTER_APP}/Contents/MacOS/AutoNoteApp" ]] && has_fix "${AFTER_APP}"; then say_ "  ✓ 修正後のアプリ: ${AFTER_APP}（版 $(app_version "${AFTER_APP}")）"
        elif [[ -x "${AFTER_APP}/Contents/MacOS/AutoNoteApp" ]]; then say_ "  ✗ ${AFTER_APP} は修正を含みません"; problem "この worktree で SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build-app.sh release を実行し直す"
        else say_ "  ✗ 修正後のアプリがありません（${AFTER_APP}）"; problem "この worktree で SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build-app.sh release を実行する（tools/whisper.xcframework が要る）"; fi
    fi
    if want C1; then
        find_before_app
        if [[ -z "${BEFORE_APP}" && ${BUILD_BEFORE} == 1 && ${DRY} == 0 ]]; then build_before; fi
        if [[ -n "${BEFORE_APP}" && -x "${BEFORE_APP}/Contents/MacOS/AutoNoteApp" ]] && ! has_fix "${BEFORE_APP}"; then say_ "  ✓ 修正前のアプリ: ${BEFORE_APP}（版 $(app_version "${BEFORE_APP}")）"
        elif [[ -n "${BEFORE_APP}" ]] && has_fix "${BEFORE_APP}"; then say_ "  ✗ --before-app のアプリが修正を含んでいます"; problem "修正前（origin/main）のビルドを --before-app に渡すか、--build-before を付ける"
        elif [[ ${BUILD_BEFORE} == 1 && ${DRY} == 1 ]]; then say_ "  ・修正前のアプリは本番で origin/main からビルドします（--build-before）"
        else say_ "  ✗ 修正前のアプリが見つかりません"; problem "--build-before を付けて実行する（origin/main を結果フォルダ内でビルド）か、--before-app で修正前の AutoNote.app を渡す"; fi
    fi
    [[ -f "${HOME}/Documents/AutoNote/_autonote/devices.json" ]] && say_ "  ✓ 登録済みデバイス（devices.json）を読める（コピーして使う）" \
        || say_ "  ! 登録済みデバイスがありません。接続したときアプリが登録を聞いてきたら「登録」を押してください（一時のデータ領域にだけ残ります）"
fi
say_ "  結果の置き場: ${OUT}"

print_problems() {
    [[ ${#PROBLEMS[@]} -gt 0 ]] || return 0
    hr "直してほしい点（${#PROBLEMS[@]} 件）"
    local i=1 x; for x in "${PROBLEMS[@]}"; do say_ "  ${i}. ${x}"; i=$((i + 1)); done
}

hr "これから行うこと（全体で 15 分ほど）"
cat <<EOF
  各条件で、ヘッドセットを一度切ってからつなぎ直します。音の出どころは Chrome のローカルのタブ（127.0.0.1、ネットワーク不要）。
    C0  アプリなし。タブで音を再生中に接続（対照）
    C1  修正前のアプリを常駐 → タブ再生中 → 接続 → 約 5 秒後に自動録音（${SECS} 秒で止める）
    C2  修正後のアプリで C1 と同じ
    C3  修正後のアプリ。接続後に「システム設定 › サウンド › 入力」を内蔵マイクに切り替え → スクリプトが手動で録音開始
    R   任意。修正後のアプリ常駐のまま、実際の Meet/Zoom に 1 人で入り、別の音を流して接続 → 自動録音
  各条件の最後に 1 回だけ「音が聞こえ続けたか (y/n/b)」と聞きます。y = 聞こえ続けた / n = 聞こえなくなった / b = 一瞬途切れて戻った。
  あなたがすること: ヘッドセットの切断・接続、タブの「有効にする」を 1 回押す、C3 で入力の切替、質問に答える。
  アプリは一時のデータ領域（${OUT}/data-*）で起動し、要約は動きません。初回は許可ダイアログが出ることがあります（許可を押す）。
EOF
if [[ ${DRY} == 1 ]]; then
    say_ ""
    say_ "[dry-run] ここまで。音・マイク・アプリ・Chrome は使っていません。前提 OK=$([[ ${#PROBLEMS[@]} == 0 ]] && echo yes || echo no)"
    print_problems
    say_ "[dry-run] 本番: cd ${ROOT} && scripts/bt-verify.sh$([[ -n "${ONLY}" ]] && echo " --only ${ONLY}")"
    exit 0
fi
if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
    print_problems; say_ ""; say_ "直してから、もう一度 scripts/bt-verify.sh を実行してください。"; exit 1
fi

# ---- Web ページ（音だけ。接続後も鳴り続ける WebAudio） ----
set_tone() { printf '{"tone":%s}\n' "$1" > "${WEB}/state.json"; }
set_tone false
cat > "${WEB}/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>bt-verify</title>
<body style="font:16px sans-serif;margin:2em">
<h2>bt-verify（ローカルのテストページ。ネットワークは使いません）</h2>
<p>このタブは最後まで開いたままにしてください。最初に下のボタンを 1 回押します。以後はスクリプトが音を切り替えます。</p>
<button id="go" style="font-size:20px;padding:.5em 1em">有効にする</button>
<pre id="st">未開始</pre>
<script>
let ctx, gain, started = false, tone = false, loop = 0;
const st = document.getElementById('st');
function show(){ st.textContent = '音: ' + (tone ? '再生中（3 秒鳴って 1 秒休む）' : '停止') + ' / ' + new Date().toLocaleTimeString(); }
function envelope(){
  if(!started) return;
  const t = ctx.currentTime; gain.gain.cancelScheduledValues(t);
  if(!tone){ gain.gain.setTargetAtTime(0, t, .02); return; }
  for(let k=0;k<2;k++){ const s=t+k*4; gain.gain.setValueAtTime(0,s); gain.gain.linearRampToValueAtTime(.3,s+.05); gain.gain.setValueAtTime(.3,s+2.95); gain.gain.linearRampToValueAtTime(0,s+3); }
}
document.getElementById('go').onclick = async () => {
  ctx = new AudioContext(); await ctx.resume();
  const osc = ctx.createOscillator(); osc.frequency.value = 440; gain = ctx.createGain(); gain.gain.value = 0;
  osc.connect(gain).connect(ctx.destination); osc.start(); started = true; show();
};
setInterval(async () => {
  try{ const r = await fetch('state.json?'+Date.now(), {cache:'no-store'}); const w = await r.json();
       if(w.tone !== tone){ tone = w.tone; envelope(); } }catch(e){}
  if(tone && started && ++loop % 8 === 0) envelope();
  show();
}, 500);
</script>
HTML
python3 -I -m http.server "${PORT}" --bind 127.0.0.1 --directory "${WEB}" >/dev/null 2>&1 & SERVER_PID=$!
sleep 0.5

# debug レベルの行（トラックごとの 10 秒ごとのコールバック数）は保存されないので、実行中はストリームで残す
/usr/bin/log stream --level debug --style compact --predicate "subsystem == \"${SUBSYSTEM}\"" > "${OUT}/stream.log" 2>&1 & STREAM_PID=$!

# ---- 一時のデータ領域 ----
make_data() {   # make_data <dir> <countdown_seconds>
    local data="$1"
    mkdir -p "${data}/vault/_autonote" "${data}/portable-mirror"
    if [[ -f "${HOME}/Documents/AutoNote/_autonote/devices.json" ]]; then
        cp "${HOME}/Documents/AutoNote/_autonote/devices.json" "${data}/vault/_autonote/devices.json"
        cp "${HOME}/Documents/AutoNote/_autonote/devices.json" "${data}/portable-mirror/devices.json"
    fi
    [[ -d "${HOME}/Library/Application Support/AutoNote/models" && ! -e "${data}/models" ]] && ln -s "${HOME}/Library/Application Support/AutoNote/models" "${data}/models"
    python3 -I - "${HOME}/Library/Application Support/AutoNote/settings.json" "${data}/settings.json" "${data}/vault" "$2" <<'PY'
import json, sys
src, dst, vault, countdown = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try: real = json.load(open(src))
except Exception: real = {}
keep = {k: real[k] for k in ("live_engine", "live_model", "final_engine", "final_model", "default_language", "voice_processing",
                             "disconnect_grace_seconds", "start_on_model_match", "filler_removal") if k in real}
keep.update({"first_run_completed": True, "launch_at_login": False, "output_folder": vault, "claude_path": "/usr/bin/false",
             "live_summary_enabled": False, "translation_mode": "off", "audio_retention_days": 365, "countdown_seconds": countdown})
json.dump(keep, open(dst, "w"), indent=2)
PY
}

FIRST_START_DONE=""
start_app() {   # start_app <app> <data>
    local app="$1" data="$2" bin="$1/Contents/MacOS/AutoNoteApp"
    say_ "  AutoNote（$([[ "${app}" == "${BEFORE_APP}" ]] && echo 修正前 || echo 修正後)）を一時のデータ領域で起動します…"
    open -n --env "AUTONOTE_DATA_DIR=${data}" "${app}" 2>>"${OUT}/open.log"
    RUNNING_APP_BIN="${bin}"
    local n=0
    until [[ -S "${data}/autonote.sock" ]]; do
        sleep 0.5; n=$((n + 1))
        (( n > 40 )) && { say_ "  ✗ 20 秒待ってもアプリが応答しません（${OUT}/open.log）"; return 1; }
    done
    if [[ ",${FIRST_START_DONE}," != *",${app},"* ]]; then
        FIRST_START_DONE="${FIRST_START_DONE},${app}"
        ask "  許可ダイアログ（マイク・システムオーディオ録音・音声認識）が出ていれば許可し、メニューバーに AutoNote が出たら Enter:"
    fi
    say_ "  ✓ 常駐しました"
}
cli() { AUTONOTE_DATA_DIR="$1" "${RUNNING_APP_BIN%/AutoNoteApp}/autonote" "${@:2}"; }

chrome_ready=0
ensure_chrome() {
    (( chrome_ready )) && return 0
    say_ "  Chrome でテストページを開きます…"
    open -a "Google Chrome" "http://127.0.0.1:${PORT}/index.html"
    ask "  開いたタブの『有効にする』を 1 回押して、Enter:"
    chrome_ready=1
}

meeting_dirs() { ls -1d "$1"/recordings/*/ 2>/dev/null | sort; }
wait_new_recording() {   # wait_new_recording <data> <before-list> <秒> → NEWREC
    local n=0 d
    NEWREC=""
    while (( n < $3 * 2 )); do
        for d in $(meeting_dirs "$1"); do grep -qxF "${d}" "$2" || { NEWREC="${d%/}"; return 0; }; done
        sleep 0.5; n=$((n + 1))
    done
    return 1
}

# run_condition <id> <題> <app: none|before|after> <mode: auto|builtin|real>
run_condition() {
    local id="$1" title="$2" which="$3" mode="$4"
    local dir="${OUT}/${id}" data="${OUT}/data-${id}" app="" t0 t1 rc=0 recorded=0 t_conn
    mkdir -p "${dir}/rec"
    hr "条件 ${id}: ${title}"
    ensure_chrome
    if bt_is_up; then
        say_ "  まずヘッドセットを切断してください（Bluetooth メニューの「接続解除」か電源オフ）"
        wait_bt down || return 1
    fi
    say_ "  切断されています（いまの出力は内蔵スピーカーなど）。"
    if [[ "${which}" != none ]]; then
        app="$([[ "${which}" == before ]] && echo "${BEFORE_APP}" || echo "${AFTER_APP}")"
        make_data "${data}" "$([[ "${mode}" == builtin ]] && echo 30 || echo 5)"
        start_app "${app}" "${data}" || { rc=92; printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${title}" "$(now)" "$(now)" "" "${rc}" >> "${TSV}"; quit_app; return 1; }
        meeting_dirs "${data}" > "${dir}/before-list.txt"
    fi
    if [[ "${mode}" == real ]]; then
        say_ "  実際の会議の用意: Chrome の Google Meet（または Zoom）に自分 1 人で入る（マイクは『既定』のまま）。"
        say_ "  別のタブ／アプリ（YouTube など）で音を流し、それを『相手の声』の代わりにします。"
        ask "  用意ができて音が鳴っていたら Enter:"
    else
        set_tone true
        sleep 2
    fi
    snap "${dir}/snap-before.json"; chrome_audio > "${dir}/chrome-before.txt"
    t0="$(now)"
    [[ "${mode}" == builtin ]] && say_ "  接続したらすぐ「システム設定 › サウンド › 入力」で内蔵マイクを選んでください（25 秒以内）。"
    say_ "  音が鳴っています。ヘッドセットを接続して耳に着け、接続の瞬間から聞こえ方に注意してください。"
    wait_bt up || { set_tone false; quit_app; return 1; }
    t_conn="$(epoch)"
    sleep 3; snap "${dir}/snap-conn.json"; chrome_audio > "${dir}/chrome-conn.txt"
    if [[ "${which}" == none ]]; then
        say_ "  ${SECS} 秒そのまま聞いてください…"
        sleep $(( SECS / 2 )); snap "${dir}/snap-during.json"; chrome_audio > "${dir}/chrome-during.txt"
        sleep $(( SECS - SECS / 2 ))
    else
        if [[ "${mode}" == builtin ]]; then
            if wait_input_builtin; then
                echo "接続から内蔵マイクへの切替まで $(( $(epoch) - t_conn )) 秒" >> "${dir}/note.txt"
                cli "${data}" start >"${dir}/start.out" 2>&1 || { rc=91; echo "autonote start が失敗: $(head -c 200 "${dir}/start.out")" >> "${dir}/note.txt"; }
            else
                rc=93; echo "25 秒待っても既定の入力が内蔵マイクにならなかった" >> "${dir}/note.txt"
            fi
        else
            say_ "  接続を検出しました。アプリの自動録音を待ちます（約 5 秒）…"
        fi
        if (( rc == 0 )) && wait_new_recording "${data}" "${dir}/before-list.txt" 60; then
            recorded=1
            echo "接続から録音フォルダができるまで $(( $(epoch) - t_conn )) 秒" >> "${dir}/note.txt"
        elif (( rc == 0 )); then
            rc=90; echo "60 秒待っても録音が始まらなかった（アプリがヘッドセットの接続を検知していない）" >> "${dir}/note.txt"
        fi
        if (( recorded )); then
            say_ "  録音中（${SECS} 秒）…音が聞こえ続けるか、注意して聞いてください"
            sleep $(( SECS / 2 )); snap "${dir}/snap-during.json"; chrome_audio > "${dir}/chrome-during.txt"
            sleep $(( SECS - SECS / 2 ))
            cli "${data}" stop >"${dir}/stop.out" 2>&1
            sleep 3
            cp -R "${NEWREC}/." "${dir}/rec/" 2>/dev/null
        fi
    fi
    snap "${dir}/snap-after.json"; chrome_audio > "${dir}/chrome-after.txt"
    t1="$(now)"
    set_tone false
    ask "  音は聞こえ続けましたか？ (y=聞こえ続けた / n=聞こえなくなった / b=一瞬途切れて戻った)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${title}" "${t0}" "${t1}" "${REPLY}" "${rc}" >> "${TSV}"
    quit_app
    say_ "  完了。"
}

T_START="$(now)"
want C0 && run_condition C0 "アプリなし・タブ再生中に接続（対照）" none auto
want C1 && run_condition C1 "修正前のアプリ常駐 → タブ再生中 → 接続 → 自動録音" before auto
want C2 && run_condition C2 "修正後のアプリ常駐 → タブ再生中 → 接続 → 自動録音" after auto
want C3 && run_condition C3 "修正後のアプリ・入力を内蔵マイク → 手動で録音開始" after builtin
if [[ ${REAL} == 1 ]] && want R; then
    ask "任意: 実際の Meet / Zoom でも 1 回試しますか？（約 2 分） (y/N)"
    [[ "${REPLY}" == [yY]* ]] && run_condition R "修正後のアプリ常駐 → 実際の会議 + 別の音 → 接続 → 自動録音" after real
fi
T_END="$(now)"

hr "ログの回収と集計"
[[ -n "${STREAM_PID}" ]] && { kill "${STREAM_PID}" 2>/dev/null; STREAM_PID=""; }
say_ "  unified log（coreaudiod / AutoNoteApp / Chrome / bluetoothd）を回収しています…（1〜2 分）"
/usr/bin/log show --start "${T_START}" --end "${T_END}" --info --style compact \
    --predicate "process == \"coreaudiod\" OR process == \"AutoNoteApp\" OR process BEGINSWITH \"Google Chrome\" OR process == \"bluetoothd\" OR subsystem == \"${SUBSYSTEM}\"" \
    > "${OUT}/unified.log" 2>&1 || true

python3 -I - "${OUT}" <<'PY'
import json, math, os, sys, wave, re
out = sys.argv[1]

def load(p, default=None):
    try: return json.load(open(p))
    except Exception: return default

def route(s):
    if not s: return "—"
    def one(k, chk):
        x = s.get(k)
        if not x: return "なし"
        return "%s %dHz/%sch%s" % (x.get("transport", "?"), int(x.get("sample_rate", 0)), x.get(chk, "?"), "・動作中" if x.get("running_somewhere") else "")
    return "出 %s / 入 %s" % (one("default_output", "out_channels"), one("default_input", "in_channels"))

def track_stats(rec, track):
    m = load(os.path.join(rec, "manifest.json"))
    if not m: return None
    files = sorted([t for t in m.get("tracks", []) if t.get("track") == track], key=lambda t: t.get("start_offset", 0))
    samples = []
    for t in files:
        try:
            w = wave.open(os.path.join(rec, t["relative_path"]), "rb")
            data = w.readframes(w.getnframes()); w.close()
            samples.extend(int.from_bytes(data[i:i+2], "little", signed=True) for i in range(0, len(data) - 1, 2))
        except Exception:
            pass
    if not samples: return {"rms": "—", "zero": "—", "len": 0}
    rms = math.sqrt(sum(x * x for x in samples) / len(samples))
    sr = 16000
    secs = [samples[i:i+sr] for i in range(0, len(samples), sr)]
    zero = sum(1 for s in secs if not any(s))
    return {"rms": "%.1f dB" % (20 * math.log10(rms / 32768)) if rms > 0 else "−∞", "zero": "%d/%d 秒" % (zero, len(secs)), "len": len(secs)}

def health(rec, track):
    m = load(os.path.join(rec, "manifest.json"))
    if not m: return "—"
    if "audio_health" not in m: return "記録なし（修正前）"
    h = next((x for x in m["audio_health"] if x.get("track") == track), None)
    if not h: return "—"
    return "欠落 %s・ゼロ %s・作り直し %s" % (h.get("no_callback_seconds"), h.get("zero_seconds"), h.get("restarts"))

log_lines = []
try:
    log_lines = open(os.path.join(out, "unified.log"), errors="replace").read().splitlines()
except Exception:
    pass
def count(t0, t1, pattern):
    rx = re.compile(pattern)
    n = 0
    for line in log_lines:
        ts = line[:19]
        if t0 <= ts <= t1 and rx.search(line): n += 1
    return n

rows = []
for line in open(os.path.join(out, "conditions.tsv")):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 6: continue
    cid, title, t0, t1, heard, rc = parts[:6]
    d = os.path.join(out, cid); rec = os.path.join(d, "rec")
    mic, sysm = track_stats(rec, "mic"), track_stats(rec, "system")
    chrome = "→".join((open(os.path.join(d, f"chrome-{k}.txt")).read().strip() or "0") if os.path.exists(os.path.join(d, f"chrome-{k}.txt")) else "?" for k in ("before", "conn", "during", "after"))
    note = open(os.path.join(d, "note.txt")).read().strip().replace("\n", " / ") if os.path.exists(os.path.join(d, "note.txt")) else ""
    rows.append([cid, title, heard or "?", rc,
                 mic["rms"] if mic else "—", mic["zero"] if mic else "—", health(rec, "mic"),
                 sysm["rms"] if sysm else "—", sysm["zero"] if sysm else "—", health(rec, "system"),
                 str(count(t0, t1, r"stopping the engine")), str(count(t0, t1, r"mic rebuild #\d+ \(")),
                 chrome, route(load(os.path.join(d, "snap-before.json"))) + " → " + route(load(os.path.join(d, "snap-during.json"))), note])

head = ["条件", "内容", "聞こえた", "rc", "マイク RMS", "マイク ゼロ", "マイク audio_health", "システム RMS", "システム ゼロ",
        "システム audio_health", "stopping the engine", "mic rebuild", "Chrome 音声 assertion（前→接続→録音中→後）", "既定の入出力（前 → 録音中）", "メモ"]
with open(os.path.join(out, "summary.md"), "w") as f:
    f.write("# bt-verify の結果\n\n")
    f.write("| " + " | ".join(head) + " |\n|" + "---|" * len(head) + "\n")
    for r in rows: f.write("| " + " | ".join(x.replace("|", "/") for x in r) + " |\n")
    f.write("\n読み方: C1 でマイクのゼロ秒がほぼ全部かつ stopping the engine ≥ 1、C2 で同じ行があっても mic rebuild ≥ 1 でマイクのゼロ秒が数秒以内なら修正が効いている。\n")
    f.write("audio_health の「欠落」= コールバックが来なかった秒、「ゼロ」= 来たが全サンプル 0 だった秒。システム音声がゼロのとき、どちらかで原因が分かれる。\n")
    f.write("rc: 0 = 正常、90 = 録音が始まらなかった、91 = autonote start 失敗、92 = アプリが起動しない、93 = 入力が内蔵マイクにならなかった。\n")
    f.write("10 秒ごとのコールバック数（debug）は stream.log にある（`grep AudioHealth stream.log`）。\n")
print(open(os.path.join(out, "summary.md")).read())
PY
say_ ""
say_ "結果: ${OUT}/summary.md（ログは ${OUT}/unified.log と ${OUT}/stream.log、録音は ${OUT}/<条件>/rec/）"
say_ "後で消すなら: rm -rf '${OUT}'（--build-before を使ったときは先に git -C '${ROOT}' worktree remove --force '${OUT}/before-src'）"
