#!/usr/bin/env python3
"""Unattended check of the Bluetooth headset microphone fix (and a search for the "can't hear the other side" /
"system track all zero" symptoms). Run through scripts/bt-verify.sh, which compiles the meter.

Per trial: optional build app (temporary AUTONOTE_DATA_DIR, no summarizer) → optional local page in a temporary Chrome
profile (tone or WebRTC loopback) → headset disconnected / connected with blueutil → auto or manual recording →
stop. An independent meter process taps all output and tells whether the source tone reached the output (Goertzel),
whether the headset output was running, and (when the headset is already on HFP) whether its own microphone picks the
tone up acoustically. Results: <out>/summary.md and <out>/results.json.

Safety (checked before each trial; unsafe → wait 5 min, give up after --wait-max minutes, exit 75):
  (i) no input device is running, (ii) no output device is running (nobody is playing audio),
  (iii) the installed AutoNote (/Applications) is not recording. If it runs idle, it is quit for the experiment and
  started again at the end. Cleanup (always): temporary Chrome, build app, meter, headset reconnected if it was
  connected, installed AutoNote relaunched if it was running. Sound budget per run: --sound-budget seconds.
Device names and addresses are never written to files: the headset is found by --bt-name (substring) at run time.
"""
import argparse, json, os, re, shutil, signal, subprocess, sys, tempfile, threading, time
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

INSTALLED_APP = "/Applications/AutoNote.app"
INSTALLED_BIN = INSTALLED_APP + "/Contents/MacOS/AutoNoteApp"
CHROME_BIN = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SUBSYSTEM = "com.yutaokoshi.autonote"
FIX_MARK = b"mic rebuild #"
TONE_DB_THRESHOLD = -50.0    # page level 0.05 ≈ −26 dBFS; anything above −50 counts as "the tone is there"


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def run(cmd, timeout=30, env=None, check=False):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        if check and p.returncode != 0:
            raise RuntimeError(f"{cmd[0]} failed: {p.stderr.strip()[:200]}")
        return p
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timeout")


class Env:
    def __init__(self, a):
        self.a = a
        self.out = a.out
        self.meter = a.meter
        self.bt_addr = None
        self.bt_input_uid = None
        self.builtin_input_uid = None
        self.original_input_uid = None   # restored at cleanup when a trial switched the default input
        self.bt_was_connected = False
        self.installed_was_running = False
        self.procs = []           # (name, Popen) to kill on cleanup
        self.app_bin = None
        self.sound_seconds = 0.0
        self.started = time.time()
        self.status_lines = []
        self.lock = threading.Lock()
        self.server = None

    # ---------- devices ----------
    def devices(self, names=False):
        p = run([self.meter, "devices"] + (["--names"] if names else []), timeout=10)
        try:
            return json.loads(p.stdout)
        except Exception:
            return {}

    def default_output(self):
        return self.devices().get("default_output") or {}

    def bt_connected(self):
        p = run(["blueutil", "--is-connected", self.bt_addr], timeout=10)
        return p.stdout.strip() == "1"

    def resolve_bt(self):
        p = run(["blueutil", "--paired", "--format", "json"], timeout=15)
        if p.returncode != 0:
            raise SystemExit(f"blueutil --paired failed (Bluetooth permission for this terminal?): {p.stderr.strip()[:200]}")
        hits = [d for d in json.loads(p.stdout) if self.a.bt_name.lower() in (d.get("name") or "").lower()]
        if len(hits) != 1:
            raise SystemExit(f"--bt-name matched {len(hits)} paired devices (need exactly 1)")
        self.bt_addr = hits[0]["address"]
        self.bt_was_connected = bool(hits[0].get("connected"))

    def resolve_bt_input_uid(self):
        info = self.devices(names=True)
        self.original_input_uid = (info.get("default_input") or {}).get("uid")
        for d in info.get("devices", []):
            if d.get("transport") == "bluetooth" and d.get("in_channels", 0) > 0 and self.a.bt_name.lower() in d.get("name", "").lower():
                self.bt_input_uid = d.get("uid")
            if d.get("transport") == "builtin" and d.get("in_channels", 0) > 0 and not self.builtin_input_uid:
                self.builtin_input_uid = d.get("uid")

    def default_input_uid(self):
        return (self.devices(names=True).get("default_input") or {}).get("uid")

    def set_default_input(self, uid):
        return run([self.meter, "set-default-input", uid], timeout=10).returncode == 0

    def bt_disconnect(self):
        run(["blueutil", "--disconnect", self.bt_addr], timeout=20)
        t = time.time()
        while time.time() - t < 30:
            if not self.bt_connected() and self.default_output().get("transport") not in ("bluetooth", None):
                time.sleep(1.5)   # let the route settle on the built-in output
                return True
            time.sleep(0.3)
        return False

    def bt_connect(self, timeout=40):
        t = time.time()
        while time.time() - t < timeout:
            run(["blueutil", "--connect", self.bt_addr], timeout=20)
            t2 = time.time()
            while time.time() - t2 < 12:
                if self.bt_connected() and self.default_output().get("transport") == "bluetooth":
                    return time.time()
                time.sleep(0.2)
        return None

    # ---------- safety ----------
    def installed_state(self):
        if run(["pgrep", "-f", INSTALLED_BIN]).returncode != 0:
            return "not_running"
        p = run([INSTALLED_APP + "/Contents/MacOS/autonote", "status", "--json"], timeout=10,
                env={k: v for k, v in os.environ.items() if k != "AUTONOTE_DATA_DIR"})
        try:
            st = json.loads(p.stdout)
            return (st.get("recorder") or {}).get("state", "unknown")
        except Exception:
            return "unknown"

    def unsafe_reasons(self):
        reasons = []
        for d in self.devices().get("devices", []):
            if d.get("transport") == "aggregate":
                continue
            if d.get("running_somewhere") and d.get("in_channels", 0) > 0:
                reasons.append(f"an input device is running ({d.get('transport')})")
            elif d.get("running_somewhere") and d.get("out_channels", 0) > 0:
                reasons.append(f"an output device is running ({d.get('transport')}): someone is playing audio")
        st = self.installed_state()
        if st not in ("not_running", "idle"):
            reasons.append(f"installed AutoNote is {st}")
        return sorted(set(reasons))

    def wait_safe(self, where):
        deadline = self.started + self.a.wait_max * 60
        while True:
            reasons = self.unsafe_reasons()
            if not reasons:
                return True
            log(f"[{where}] not safe: {'; '.join(reasons)}")
            if self.a.dry_run or time.time() + 300 > deadline:
                return False
            log("waiting 5 minutes…")
            time.sleep(300)

    def quit_installed(self):
        if run(["pgrep", "-f", INSTALLED_BIN]).returncode == 0:
            self.installed_was_running = True
            log("quitting the installed AutoNote for the experiment (it is idle)")
            run(["osascript", "-e", f'tell application "{INSTALLED_APP}" to quit'], timeout=20)
            for _ in range(40):
                if run(["pgrep", "-f", INSTALLED_BIN]).returncode != 0:
                    break
                time.sleep(0.5)

    # ---------- page server ----------
    def start_server(self):
        env = self
        pages = os.path.join(self.a.root, "scripts", "bt-verify-pages")

        class H(SimpleHTTPRequestHandler):
            def __init__(self, *args, **kw):
                super().__init__(*args, directory=pages, **kw)

            def log_message(self, *a):
                pass

            def do_POST(self):
                n = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(n).decode("utf-8", "replace")
                with env.lock:
                    env.status_lines.append({"t": time.time(), **(json.loads(body) if body.startswith("{") else {"raw": body})})
                self.send_response(204)
                self.end_headers()

        self.server = ThreadingHTTPServer(("127.0.0.1", self.a.port), H)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    # ---------- processes ----------
    def spawn(self, name, cmd, env=None, stdout=None):
        p = subprocess.Popen(cmd, env=env, stdout=stdout or subprocess.DEVNULL, stderr=subprocess.STDOUT, start_new_session=True)
        self.procs.append((name, p))
        return p

    def kill(self, name):
        for n, p in list(self.procs):
            if n == name:
                try:
                    os.killpg(p.pid, signal.SIGTERM)
                except Exception:
                    pass
                try:
                    p.wait(timeout=8)
                except Exception:
                    try:
                        os.killpg(p.pid, signal.SIGKILL)
                    except Exception:
                        pass
                self.procs.remove((n, p))

    def open_page(self, trial_dir, page):
        prof = os.path.join(trial_dir, "chrome-profile")
        url = f"http://127.0.0.1:{self.a.port}/{page}.html"
        cmd = [CHROME_BIN, f"--user-data-dir={prof}", "--autoplay-policy=no-user-gesture-required",
               "--use-fake-ui-for-media-stream", "--no-first-run", "--no-default-browser-check",
               "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
               "--disable-backgrounding-occluded-windows", "--new-window", url]
        self.spawn("chrome", cmd)
        self.page_since = time.time()

    def close_page(self):
        if any(n == "chrome" for n, _ in self.procs):
            self.sound_seconds += time.time() - self.page_since
        self.kill("chrome")
        # Any helper of our temporary profile that outlived the group.
        run(["pkill", "-f", f"--user-data-dir={self.out}/"], timeout=10)

    def start_app(self, app, data):
        self.app_bin = os.path.join(app, "Contents", "MacOS", "AutoNoteApp")
        run(["open", "-n", "--env", f"AUTONOTE_DATA_DIR={data}", app], timeout=20)
        for _ in range(60):
            if os.path.exists(os.path.join(data, "autonote.sock")):
                return True
            time.sleep(0.5)
        return False

    def quit_app(self):
        if self.app_bin:
            run(["pkill", "-f", self.app_bin])
            for _ in range(20):
                if run(["pgrep", "-f", self.app_bin]).returncode != 0:
                    break
                time.sleep(0.5)
            self.app_bin = None

    def cli(self, data, *args):
        return run([os.path.join(os.path.dirname(self.app_bin), "autonote"), *args], timeout=30, env={**os.environ, "AUTONOTE_DATA_DIR": data})

    def cleanup(self):
        log("cleanup")
        self.close_page()
        for n, _ in list(self.procs):
            self.kill(n)
        self.quit_app()
        if self.original_input_uid and self.default_input_uid() != self.original_input_uid:
            log("restoring the default input")
            self.set_default_input(self.original_input_uid)
        if self.bt_addr and self.bt_was_connected and not self.bt_connected():
            log("reconnecting the headset")
            if not self.bt_connect():
                log("! could not reconnect the headset (power off / out of range?)")
        if self.installed_was_running and run(["pgrep", "-f", INSTALLED_BIN]).returncode != 0:
            log("starting the installed AutoNote again")
            run(["open", INSTALLED_APP], timeout=20)
        if self.server:
            self.server.shutdown()


def make_data(env, data, countdown):
    home = os.path.expanduser("~")
    os.makedirs(os.path.join(data, "vault", "_autonote"), exist_ok=True)
    os.makedirs(os.path.join(data, "portable-mirror"), exist_ok=True)
    dj = os.path.join(home, "Documents", "AutoNote", "_autonote", "devices.json")
    if os.path.exists(dj):
        shutil.copy(dj, os.path.join(data, "vault", "_autonote", "devices.json"))
        shutil.copy(dj, os.path.join(data, "portable-mirror", "devices.json"))
    models = os.path.join(home, "Library", "Application Support", "AutoNote", "models")
    if os.path.isdir(models) and not os.path.exists(os.path.join(data, "models")):
        os.symlink(models, os.path.join(data, "models"))
    try:
        real = json.load(open(os.path.join(home, "Library", "Application Support", "AutoNote", "settings.json")))
    except Exception:
        real = {}
    keep = {k: real[k] for k in ("live_engine", "live_model", "final_engine", "final_model", "default_language", "voice_processing",
                                 "disconnect_grace_seconds", "start_on_model_match", "filler_removal") if k in real}
    keep.update({"first_run_completed": True, "launch_at_login": False, "output_folder": os.path.join(data, "vault"),
                 "claude_path": "/usr/bin/false", "live_summary_enabled": False, "translation_mode": "off",
                 "audio_retention_days": 365, "countdown_seconds": countdown})
    json.dump(keep, open(os.path.join(data, "settings.json"), "w"), indent=2)


def recordings(data):
    d = os.path.join(data, "recordings")
    return set(os.listdir(d)) if os.path.isdir(d) else set()


# ---------- one trial ----------
def trial(env, spec, idx):
    tid = f"{idx:02d}-{spec['id']}"
    tdir = os.path.join(env.out, tid)
    os.makedirs(tdir, exist_ok=True)
    res = {"trial": tid, **spec, "events": {}}
    try:
        trial_body(env, spec, res, tdir)
    except KeyboardInterrupt:
        res["error"] = "interrupted"
        raise
    except Exception as e:   # one broken trial must not end the run
        res["error"] = f"exception: {e!r}"
    finally:
        if res.get("error") or res.get("skipped"):
            log(f"  {tid}: {res.get('error') or res.get('skipped')}")
        if "skipped" not in res:
            analyze_trial(env, res, tdir)
        json.dump(res, open(os.path.join(tdir, "result.json"), "w"), indent=1, default=str)
    return res


def trial_body(env, spec, res, tdir):
    """spec: id, app (none|before|after), page (none|tone|webrtc), order (page_then_connect|connect_then_page),
    start (auto|manual|none), countdown, mic_probe (bool: meter opens the headset mic when HFP)."""
    a = env.a
    tid = res["trial"]
    ev = res["events"]
    log(f"=== trial {tid}: {spec}")
    if not env.wait_safe(tid):
        res["skipped"] = "unsafe"
        return res
    if env.sound_seconds + spec.get("sound_estimate", 60) > a.sound_budget:
        res["skipped"] = "sound budget"
        return res
    # Short path: the app's Unix socket lives in the data directory (sun_path is 104 bytes).
    data = tempfile.mkdtemp(prefix=f"btv{tid[:2]}-")
    res["data_dir"] = data
    app = {"before": a.before_app, "after": a.after_app}.get(spec["app"])
    meter_out = os.path.join(tdir, "meter.jsonl")
    with env.lock:
        env.status_lines = []
    try:
        if not env.bt_disconnect():
            res["error"] = "could not disconnect the headset"
            return res
        ev["disconnected"] = time.time()
        if app:
            make_data(env, data, spec["countdown"])
            if not env.start_app(app, data):
                res["error"] = "app did not start"
                return res
            ev["app_started"] = time.time()
            time.sleep(2)
        before = recordings(data) if app else set()
        mic_args = []
        if spec.get("mic_probe") and env.bt_input_uid:
            mic_args = ["--mic-uid", env.bt_input_uid, "--mic-after", str(spec.get("mic_after", 18)), "--mic-if-hfp"]
            if spec.get("mic_force"):
                mic_args.remove("--mic-if-hfp")
        total = 6 + 30 + spec.get("countdown", 0) + a.seconds + 15
        env.spawn("meter", [env.meter, "meter", "--seconds", str(total), "--out", meter_out, "--freqs", "440,660"] + mic_args)
        ev["meter_started"] = time.time()
        if spec["page"] != "none" and spec["order"] == "page_then_connect":
            env.open_page(tdir, spec["page"])
            ev["page_opened"] = time.time()
            time.sleep(4)
        tc = env.bt_connect()
        if not tc:
            res["error"] = "headset did not connect (power off / out of range?)"
            return res
        ev["connected"] = tc
        if spec["page"] != "none" and spec["order"] == "connect_then_page":
            time.sleep(spec.get("page_delay", 3))
            env.open_page(tdir, spec["page"])
            ev["page_opened"] = time.time()
        rec = None
        if app and spec["start"] == "manual":
            time.sleep(spec.get("manual_delay", 6))
            p = env.cli(data, "start")
            ev["manual_start"] = time.time()
            if p.returncode != 0:
                res["error"] = f"autonote start failed: {p.stdout.strip()[:120]} {p.stderr.strip()[:120]}"
        if app and spec["start"] in ("auto", "manual") and "error" not in res:
            t = time.time()
            while time.time() - t < spec.get("countdown", 0) + 30:
                new = recordings(data) - before
                if new:
                    rec = os.path.join(data, "recordings", sorted(new)[0])
                    ev["recording_seen"] = time.time()
                    break
                time.sleep(0.3)
            if not rec:
                res["error"] = "recording did not start"
        listen = a.seconds if rec or not app else 8
        t0 = time.time()
        if rec and spec.get("switch_input"):
            # Default input → built-in microphone, later back to the headset, while recording from the default input.
            plan = [(spec.get("switch_at", 6), env.builtin_input_uid, "switched_to_builtin"),
                    (spec.get("switch_back_at", 14), env.bt_input_uid, "switched_back")]
            for at, uid, name in plan:
                time.sleep(max(0, t0 + at - time.time()))
                if not uid or not env.set_default_input(uid):
                    res["error"] = f"could not set the default input ({name})"
                    break
                ev[name] = time.time()
        time.sleep(max(0, t0 + listen - time.time()))
        if rec:
            env.cli(data, "stop")
            ev["stopped"] = time.time()
            time.sleep(3)
            shutil.copytree(rec, os.path.join(tdir, "rec"), dirs_exist_ok=True)
        ev["end"] = time.time()
    finally:
        env.close_page()
        env.kill("meter")
        env.quit_app()
        with env.lock:
            res["page_status"] = list(env.status_lines)
    return res


# ---------- analysis ----------
def wav_samples(path):
    import wave
    w = wave.open(path, "rb")
    data = w.readframes(w.getnframes())
    w.close()
    import array
    arr = array.array("h")
    arr.frombytes(data[: len(data) // 2 * 2])
    return arr


def track_stats(rec, track):
    m = json.load(open(os.path.join(rec, "manifest.json")))
    files = sorted([t for t in m.get("tracks", []) if t.get("track") == track], key=lambda t: t.get("start_offset", 0))
    s = []
    for t in files:
        try:
            s.extend(wav_samples(os.path.join(rec, t["relative_path"])))
        except Exception:
            pass
    if not s:
        return None
    import math
    secs = [s[i:i + 16000] for i in range(0, len(s), 16000)]
    zero = sum(1 for x in secs if not any(x))
    rms = math.sqrt(sum(v * v for v in s) / len(s))
    return {"seconds": len(secs), "zero_seconds": zero, "rms_db": round(20 * math.log10(rms / 32768), 1) if rms > 0 else None}


def analyze_trial(env, res, tdir):
    ev = res.get("events", {})
    lines = []
    try:
        lines = [json.loads(x) for x in open(os.path.join(tdir, "meter.jsonl")) if x.strip()]
    except Exception:
        pass
    freq = 660 if res.get("page") == "webrtc" else 440
    tc = ev.get("connected")
    end = ev.get("end", time.time())
    after = [l for l in lines if tc and tc + 3 <= l["t"] <= end and ev.get("page_opened", 1e18) + 2 <= l["t"]]
    pre = [l for l in lines if ev.get("page_opened") and ev["page_opened"] + 2 <= l["t"] < (tc or 0)]

    def frac(xs, f):
        return round(sum(1 for x in xs if f(x)) / len(xs), 2) if xs else None
    key = f"tap_tone_{freq}_db"
    m = {
        "windows_after_connect": len(after),
        "tap_tone_before_connect": frac(pre, lambda x: x.get(key, -200) > TONE_DB_THRESHOLD),
        "tap_tone_after_connect": frac(after, lambda x: x.get(key, -200) > TONE_DB_THRESHOLD),
        "tap_callbacks_zero_windows": frac(after, lambda x: x.get("tap_callbacks", 0) == 0),
        "bt_out_running": frac(after, lambda x: x.get("out_transport") == "bluetooth" and x.get("out_running")),
        "bt_out_hfp": frac(after, lambda x: x.get("out_transport") == "bluetooth" and x.get("out_rate", 0) <= 24000),
    }
    mic_on = [l for l in after if l.get("mic_state") == "on"]
    m["mic_probe_state"] = sorted({l.get("mic_state") for l in lines}) if lines else []
    m["mic_probe_tone"] = frac(mic_on, lambda x: x.get(f"mic_tone_{freq}_db", -200) > -70)
    m["mic_probe_tone_db_max"] = max((x.get(f"mic_tone_{freq}_db", -200) for x in mic_on), default=None)
    res["meter"] = m
    ps = [s for s in res.get("page_status", []) if tc and s["t"] >= tc + 3]
    if ps:
        res["page"] = res["page"]
        res["page_summary"] = {
            "ctx_running": frac(ps, lambda s: s.get("ctx") == "running"),
            "audio_playing": frac(ps, lambda s: s.get("audio_paused") is False) if res["page"] == "webrtc" else None,
            "remote_level_ok": frac(ps, lambda s: (s.get("remote_level_db") or -200) > -50) if res["page"] == "webrtc" else None,
            "mic_open": frac(ps, lambda s: s.get("mic") == "open") if res["page"] == "webrtc" else None,
            "errors": sorted({s.get("error") for s in ps if s.get("error")}),
        }
    rec = os.path.join(tdir, "rec")
    if os.path.exists(os.path.join(rec, "manifest.json")):
        man = json.load(open(os.path.join(rec, "manifest.json")))
        res["recording"] = {"mic": track_stats(rec, "mic"), "system": track_stats(rec, "system"),
                            "audio_health": man.get("audio_health"), "silence_warning": man.get("silence_warning")}
    # verdicts
    r = res.get("recording") or {}
    mic, sysm = r.get("mic"), r.get("system")
    v = {}
    if mic:
        v["mic_dead"] = mic["zero_seconds"] >= 0.8 * mic["seconds"]
    if sysm:
        v["system_zero"] = sysm["zero_seconds"] >= 0.8 * sysm["seconds"]
    if res.get("page") != "none" and m["tap_tone_after_connect"] is not None:
        v["heard"] = bool(m["tap_tone_after_connect"] >= 0.8 and (m["bt_out_running"] or 0) >= 0.8)
    if ev.get("switched_to_builtin") and ev.get("switched_back"):
        # While the built-in mic is the default: does the headset leave HFP (nobody holds its input any more)?
        win = [l for l in lines if ev["switched_to_builtin"] + 3 <= l["t"] < ev["switched_back"]]
        m["hfp_while_builtin"] = frac(win, lambda x: x.get("out_transport") == "bluetooth" and x.get("out_rate", 0) <= 24000)
        m["default_in_builtin"] = frac(win, lambda x: x.get("in_transport") == "builtin")
        v["stuck_on_hfp"] = (m["hfp_while_builtin"] or 0) >= 0.5
    res["verdict"] = v


def attach_logs(env, results):
    if not results:
        return
    t0 = min(r["events"].get("disconnected", time.time()) for r in results if r.get("events")) - 5
    t1 = max(r["events"].get("end", time.time()) for r in results if r.get("events")) + 5
    path = os.path.join(env.out, "unified.log")
    fmt = "%Y-%m-%d %H:%M:%S"
    p = run(["/usr/bin/log", "show", "--start", time.strftime(fmt, time.localtime(t0)), "--end", time.strftime(fmt, time.localtime(t1)),
             "--info", "--style", "compact", "--predicate",
             f'process == "coreaudiod" OR process == "AutoNoteApp" OR process BEGINSWITH "Google Chrome" OR process == "bluetoothd" OR subsystem == "{SUBSYSTEM}"'],
            timeout=600)
    open(path, "w").write(p.stdout)
    lines = p.stdout.splitlines()
    import datetime
    for r in results:
        e = r.get("events") or {}
        if "disconnected" not in e:
            continue
        a = datetime.datetime.fromtimestamp(e["disconnected"]).strftime(fmt)
        b = datetime.datetime.fromtimestamp(e.get("end", e["disconnected"] + 60)).strftime(fmt)
        sel = [l for l in lines if a <= l[:19] <= b]
        r["log"] = {
            "stopping_the_engine": sum("stopping the engine" in l for l in sel),
            "mic_rebuild": sum(bool(re.search(r"mic rebuild #\d+ \(", l)) for l in sel),
            "mic_restarted": sum("restarted the engine" in l for l in sel),
            "mic_gave_up": sum("mic gave up" in l for l in sel),
            "config_changed": sum("configuration changed" in l and "AutoNoteApp" in l for l in sel),
            "profile_change": sum("Request profile Change" in l for l in sel),
            "io_stopped": sum("IO Stopped" in l for l in sel),
        }
        json.dump(r, open(os.path.join(env.out, r["trial"], "result.json"), "w"), indent=1, default=str)


def write_summary(env, results, plan_name):
    json.dump(results, open(os.path.join(env.out, "results.json"), "w"), indent=1, default=str)
    head = ["trial", "app", "page", "order", "start", "cd", "mic zero/s", "sys zero/s", "mic health (no-cb/zero/rebuild)",
            "sys health", "tone after conn (tap)", "BT out running", "HFP", "mic probe tone", "page", "stop-engine", "rebuild",
            "verdict", "note"]
    rows = []
    for r in results:
        rec = r.get("recording") or {}
        def tz(t):
            x = rec.get(t)
            return f"{x['zero_seconds']}/{x['seconds']}" if x else "—"
        def hh(t):
            h = next((x for x in (rec.get("audio_health") or []) if x.get("track") == t), None)
            return f"{h['no_callback_seconds']}/{h['zero_seconds']}/{h['restarts']}" if h else ("none (old build)" if rec else "—")
        m = r.get("meter") or {}
        ps = r.get("page_summary") or {}
        lg = r.get("log") or {}
        v = r.get("verdict") or {}
        verdict = ", ".join(k for k, val in v.items() if val and k != "heard")
        if "heard" in v:
            verdict = (verdict + ", " if verdict else "") + ("heard" if v["heard"] else "NOT HEARD")
        page = ""
        if ps:
            page = f"ctx {ps.get('ctx_running')}" + (f" play {ps.get('audio_playing')} remote {ps.get('remote_level_ok')} mic {ps.get('mic_open')}" if r.get("page") == "webrtc" else "")
        rows.append([r["trial"], r["app"], r["page"], r.get("order", ""), r["start"], str(r.get("countdown", "")), tz("mic"), tz("system"),
                     hh("mic"), hh("system"), str(m.get("tap_tone_after_connect")), str(m.get("bt_out_running")), str(m.get("bt_out_hfp")),
                     f"{m.get('mic_probe_tone')} ({m.get('mic_probe_tone_db_max')})", page, str(lg.get("stopping_the_engine", "")),
                     str(lg.get("mic_rebuild", "")), verdict, r.get("error") or r.get("skipped") or ""])
    with open(os.path.join(env.out, "summary.md"), "w") as f:
        f.write(f"# bt-verify ({plan_name}) {time.strftime('%Y-%m-%d %H:%M')}\n\n")
        f.write(f"sound played: {int(env.sound_seconds)} s\n\n")
        f.write("| " + " | ".join(head) + " |\n|" + "---|" * len(head) + "\n")
        for row in rows:
            f.write("| " + " | ".join(str(x).replace("|", "/") for x in row) + " |\n")
        f.write("\nColumns: tone after conn = share of 0.5 s windows (from connect+3 s) where the independent tap heard the page's tone "
                f"(> {TONE_DB_THRESHOLD} dBFS, Goertzel); BT out running = share where the default output is the headset and running; "
                "HFP = share where it runs at ≤ 24 kHz; mic probe tone = share where the headset's own mic (opened by the meter only once "
                "HFP is up) picked the tone up, with the max level. mic/sys zero = all-zero seconds of the AutoNote tracks. "
                "health = manifest audio_health (seconds without callbacks / all-zero seconds / rebuilds).\n")
    print(open(os.path.join(env.out, "summary.md")).read())


# ---------- plans ----------
def plans(a):
    A = dict(app="after", page="tone", order="page_then_connect", start="auto", countdown=5, mic_probe=True)
    B = dict(A, app="before")
    p = {
        "baseline": [dict(id="B0-noapp-tone-mic", app="none", page="tone", order="connect_then_page", start="none", countdown=0,
                          mic_probe=True, mic_force=True, mic_after=10, page_delay=2),
                     dict(id="B1-noapp-tone", app="none", page="tone", order="page_then_connect", start="none", countdown=0, mic_probe=False)],
        "repro": [dict(B, id=f"R{i}-before-auto5") for i in range(1, a.repeat_before + 1)],
        "verify": [dict(A, id=f"V{i}-after-auto5") for i in range(1, a.repeat_after + 1)],
        # Manual start records from the default input (deviceUID nil); the default input moves mid-recording.
        "switch": [dict(A, id=f"S{i}-after-manual-switch-input", order="connect_then_page", start="manual", countdown=30,
                        manual_delay=4, page_delay=1, mic_probe=False, switch_input=True) for i in range(1, a.repeat_after + 1)],
        "explore": [],
    }
    for build in ("before", "after"):
        W = dict(app=build, page="webrtc", mic_probe=True)
        p["explore"] += [
            dict(W, id=f"E1-{build}-webrtc-first-auto5", order="page_then_connect", start="auto", countdown=5),
            dict(W, id=f"E2-{build}-webrtc-first-auto0", order="page_then_connect", start="auto", countdown=0),
            dict(W, id=f"E3-{build}-webrtc-first-auto30", order="page_then_connect", start="auto", countdown=30, sound_estimate=90),
            dict(W, id=f"E4-{build}-connect-then-webrtc-auto5", order="connect_then_page", start="auto", countdown=5, page_delay=1),
            dict(W, id=f"E5-{build}-webrtc-first-manual", order="page_then_connect", start="manual", countdown=30, manual_delay=8),
        ]
    p["explore"].insert(0, dict(id="E0-noapp-webrtc", app="none", page="webrtc", order="page_then_connect", start="none", countdown=0, mic_probe=True))
    p["switch_before"] = [dict(x, app="before", id=x["id"].replace("after", "before")) for x in p["switch"][:2]]
    p["all"] = p["baseline"] + p["repro"] + p["verify"]
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--meter", required=True)
    ap.add_argument("--bt-name", default=os.environ.get("BT_VERIFY_NAME", ""))
    ap.add_argument("--plan", default="all", help="baseline | repro | verify | switch | switch_before | explore | all (= baseline+repro+verify) | comma list")
    ap.add_argument("--only", default="", help="comma list of trial id prefixes")
    ap.add_argument("--before-app", default="")
    ap.add_argument("--after-app", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seconds", type=int, default=20)
    ap.add_argument("--repeat-before", type=int, default=3)
    ap.add_argument("--repeat-after", type=int, default=5)
    ap.add_argument("--sound-budget", type=int, default=900)
    ap.add_argument("--wait-max", type=int, default=120, help="minutes to wait for safe conditions")
    ap.add_argument("--port", type=int, default=8767)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    if not a.bt_name and not a.dry_run:
        raise SystemExit("--bt-name (or BT_VERIFY_NAME) is required: a substring of the headset's name")
    os.makedirs(a.out, exist_ok=True)
    env = Env(a)
    allp = plans(a)
    chosen = []
    for name in a.plan.split(","):
        chosen += allp[name]
    if a.only:
        chosen = [s for s in chosen if any(s["id"].startswith(x) for x in a.only.split(","))]
    needs = {s["app"] for s in chosen}
    problems = []
    if shutil.which("blueutil") is None:
        problems.append("blueutil is missing (brew install blueutil)")
    if not os.path.exists(CHROME_BIN):
        problems.append("Google Chrome is missing")
    for which, path in (("before", a.before_app), ("after", a.after_app)):
        if which in needs:
            b = os.path.join(path, "Contents", "MacOS", "AutoNoteApp")
            if not os.path.exists(b):
                problems.append(f"{which} app missing: {path}")
            elif (FIX_MARK in open(b, "rb").read()) != (which == "after"):
                problems.append(f"{which} app {'lacks' if which == 'after' else 'has'} the fix: {path}")
    if problems:
        print("\n".join("✗ " + p for p in problems))
        return 1
    if not a.bt_name:
        print("[dry-run] no --bt-name: headset not looked up")
        print("[dry-run] nothing was played, connected or started")
        return 0
    env.resolve_bt()
    log(f"headset found (connected: {env.bt_was_connected}); trials: {[s['id'] for s in chosen]}")
    if a.dry_run:
        reasons = env.unsafe_reasons()
        print("safe now" if not reasons else "not safe now: " + "; ".join(reasons))
        print("[dry-run] nothing was played, connected or started")
        return 0

    def on_signal(sig, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, on_signal)
    results = []
    code = 0
    try:
        if not env.wait_safe("start"):
            log("never became safe within --wait-max; nothing was done")
            return 75
        if not env.bt_was_connected:
            if not env.bt_connect():
                log("headset does not connect (power off / out of range?)")
                return 76
            env.bt_was_connected = True   # leave it connected afterwards
        env.resolve_bt_input_uid()
        env.quit_installed()
        env.start_server()
        for i, spec in enumerate(chosen, 1):
            results.append(trial(env, spec, i))
            time.sleep(3)
    except KeyboardInterrupt:
        log("interrupted")
        code = 130
    finally:
        env.cleanup()
    attach_logs(env, results)
    write_summary(env, results, a.plan)
    return code


if __name__ == "__main__":
    sys.exit(main())
