import http.server
import json
import os
import socket
import threading
import unittest

from helpers import STANDARD, SandboxTest, write

DAY0 = "2026-12-02T11:00:00+09:00"


class Hook(http.server.BaseHTTPRequestHandler):
    received = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        Hook.received.append((self.path, json.loads(body.decode("utf-8"))))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *a):
        pass


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class NotifyTests(SandboxTest):
    def setUp(self):
        super().setUp()
        Hook.received = []
        self.port = free_port()
        self.url = "http://127.0.0.1:%d/services/SECRET-TOKEN" % self.port
        self.server = None

    def tearDown(self):
        if self.server:
            self.server.shutdown()
            self.server.server_close()
        super().tearDown()

    def start_server(self):
        self.server = http.server.HTTPServer(("127.0.0.1", self.port), Hook)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def all_state_text(self):
        out = []
        for base in (self.sb.state, self.sb.logs):
            for d, _, files in os.walk(base):
                for n in files:
                    with open(os.path.join(d, n), encoding="utf-8", errors="replace") as f:
                        out.append(f.read())
        return "\n".join(out)

    def test_slack_failure_goes_to_outbox_and_is_resent(self):
        self.sb.set_config(NOTIFY_MODE="slack", SLACK_WEBHOOK_URL=self.url)
        proc = self.sb.share(self.sb.vault_file(STANDARD), now=DAY0)
        self.assertOk(proc)  # sharing worked; only the notice failed
        outbox = os.path.join(self.sb.state, "outbox")
        self.assertEqual(len(os.listdir(outbox)), 1)
        self.assertNotIn("SECRET-TOKEN", self.all_state_text())
        self.assertNotIn("SECRET-TOKEN", proc.stdout + proc.stderr)
        self.start_server()
        self.assertOk(self.sb.patrol(now="2026-12-02T12:00:00+09:00"))
        self.assertEqual(os.listdir(outbox), [])
        self.assertEqual(len(Hook.received), 1)
        self.assertEqual(Hook.received[0][0], "/services/SECRET-TOKEN")
        self.assertIn("議事録が並びました", Hook.received[0][1]["text"])

    def test_outbox_older_than_three_days_goes_to_todo_once(self):
        self.sb.set_config(NOTIFY_MODE="slack", SLACK_WEBHOOK_URL=self.url)
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD), now=DAY0))
        self.assertOk(self.sb.patrol(now="2026-12-04T12:00:00+09:00"))
        self.assertNotIn("知らせを送れていません", self.sb.state_file("todo.md"))
        self.assertOk(self.sb.patrol(now="2026-12-05T12:00:00+09:00"))
        self.assertOk(self.sb.patrol(now="2026-12-06T12:00:00+09:00"))
        self.assertEqual(self.sb.state_file("todo.md").count("知らせを送れていません"), 1)
        self.assertNotIn("SECRET-TOKEN", self.sb.state_file("todo.md"))

    def test_webhook_from_op_reference(self):
        self.start_server()
        fake_op = os.path.join(self.sb.root, "fake-op")
        write(fake_op, "#!/bin/sh\n[ \"$1\" = read ] && [ \"$2\" = \"op://Vault/Item/url\" ] && echo '%s'\n" % self.url)
        os.chmod(fake_op, 0o755)
        self.sb.set_config(NOTIFY_MODE="slack", SLACK_WEBHOOK_OP_REF="op://Vault/Item/url", OP_CMD=fake_op)
        proc = self.sb.share(self.sb.vault_file(STANDARD), now=DAY0)
        self.assertOk(proc)
        self.assertEqual(len(Hook.received), 1)
        self.assertNotIn("SECRET-TOKEN", proc.stdout + proc.stderr + self.all_state_text())

    def test_op_that_cannot_be_found_says_to_set_op_cmd(self):
        # C-F5 / U-F1 (round 2): launchd's PATH has no Homebrew, so `op` is not found there.
        self.sb.set_config(NOTIFY_MODE="slack", SLACK_WEBHOOK_OP_REF="op://Vault/Item/url", OP_CMD="op-not-installed")
        proc = self.sb.share(self.sb.vault_file(STANDARD), now=DAY0)
        self.assertOk(proc)
        self.assertIn("OP_CMD", proc.stdout)
        self.assertIn("絶対パス", proc.stdout)

    def test_webhook_url_without_a_scheme_stays_secret_and_goes_to_outbox(self):
        self.sb.set_config(NOTIFY_MODE="slack", SLACK_WEBHOOK_URL="hooks.example.invalid/services/SECRET-TOKEN")
        proc = self.sb.share(self.sb.vault_file(STANDARD), now=DAY0)
        self.assertOk(proc)
        self.assertNotIn("Traceback", proc.stderr)
        self.assertNotIn("SECRET-TOKEN", proc.stdout + proc.stderr + self.all_state_text())
        self.assertEqual(len(os.listdir(os.path.join(self.sb.state, "outbox"))), 1)

    def test_macos_mode_uses_notify_cmd_and_notices_file(self):
        seen = os.path.join(self.sb.root, "notified.txt")
        fake = os.path.join(self.sb.root, "fake-notify")
        write(fake, '#!/bin/sh\nprintf "%%s|%%s\\n" "$1" "$2" >> "%s"\n' % seen)
        os.chmod(fake, 0o755)
        self.sb.set_config(NOTIFY_MODE="macos", NOTIFY_CMD=fake)
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD), now=DAY0))
        with open(seen, encoding="utf-8") as f:
            line = f.read()
        self.assertIn("議事録が並びました", line)
        # U-F7: a plain notice goes to notices.md; todo.md is only for things that need a hand
        self.assertIn("議事録が並びました", self.sb.state_file("notices.md"))
        self.assertNotIn("議事録が並びました", self.sb.state_file("todo.md"))

    def test_op_read_runs_once_per_run(self):
        # U-F5: each `op read` may ask for approval, so one run reads the webhook URL only once.
        count = os.path.join(self.sb.root, "op-count")
        fake_op = os.path.join(self.sb.root, "fake-op")
        write(fake_op, "#!/bin/sh\necho x >> '%s'\necho '%s'\n" % (count, self.url))
        os.chmod(fake_op, 0o755)
        self.sb.set_config(NOTIFY_MODE="slack", SLACK_WEBHOOK_OP_REF="op://Vault/Item/url", OP_CMD=fake_op)
        from helpers import NO_TRANSCRIPT, TRANSCRIPT_ONLY
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD), now=DAY0))
        self.assertOk(self.sb.share(self.sb.vault_file(NO_TRANSCRIPT), now=DAY0))
        self.assertEqual(len(os.listdir(os.path.join(self.sb.state, "outbox"))), 2)
        os.remove(count)
        self.start_server()
        self.assertOk(self.sb.share(self.sb.vault_file(TRANSCRIPT_ONLY), now=DAY0))  # 2 resent + 1 new
        self.assertEqual(len(Hook.received), 3)
        with open(count) as f:
            self.assertEqual(len(f.read().split()), 1)

    def test_macos_mode_failure_goes_to_outbox(self):
        self.sb.set_config(NOTIFY_MODE="macos", NOTIFY_CMD="/usr/bin/false")
        self.assertOk(self.sb.share(self.sb.vault_file(STANDARD), now=DAY0))
        self.assertEqual(len(os.listdir(os.path.join(self.sb.state, "outbox"))), 1)


if __name__ == "__main__":
    unittest.main()
