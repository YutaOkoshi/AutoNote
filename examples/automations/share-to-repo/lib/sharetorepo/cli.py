"""Command lines of share-meeting.sh and daily-patrol.sh."""
import os
import sys

from .config import Config, ConfigError

SHARE_USAGE = """使い方:
  share-meeting.sh <会議ファイル> [--kind internal|customer] [--customer <相手先>] [--recording <録画のファイル名>]
                   [--recorded-by <録った人の呼び名>]
      --kind を省くと internal（社内）。顧客の会議は --kind customer を付ける（--recording を渡しても種類は変わらない）
      --recording は受け取り箱でのファイル名（パスを付けても名前だけを使う）。1 本の録画は 1 つの会議に付ける
      --recorded-by を省くと、customer は DEFAULT_RECORDED_BY、internal は OWNER_NAME
  share-meeting.sh --unshare <autonote_id>
  share-meeting.sh --recording-deleted <autonote_id>   （録画を消したことを記録し、置き場の議事録に載せる）
  share-meeting.sh --recording-deleted <autonote_id> --undo   （間違って「消した」になったものを「まだ」に戻す）
  share-meeting.sh --retry-pending
  share-meeting.sh --rebuild-index
  share-meeting.sh --rebuild-mirror
  share-meeting.sh --print-template README.md|CLAUDE.md|mirror-readme.md   （日数を差し込んだ雛形を出す）"""


def _usage(msg=None):
    if msg:
        print(msg, file=sys.stderr)
    print(SHARE_USAGE, file=sys.stderr)
    return 2


def _config():
    """The settings, or None after saying on stderr what is wrong with them (the caller ends with 2)."""
    try:
        cfg = Config()
    except ConfigError as e:
        print("設定が正しくありません: %s" % e, file=sys.stderr)
        return None
    if not os.path.isfile(cfg.config_path):
        # A mistyped SHARE_CONFIG would otherwise run on defaults without a word.
        print("警告: 設定ファイルがありません: %s（既定値と環境変数だけで動かします）" % cfg.config_path, file=sys.stderr)
    return cfg


def main_share(argv):
    from .share import Sharer
    if not argv or argv[0] in ("-h", "--help"):
        return _usage() if not argv else (print(SHARE_USAGE) or 0)
    single = {"--retry-pending": "retry_pending", "--rebuild-index": "rebuild_index",
              "--rebuild-mirror": "rebuild_mirror"}
    cfg = _config()
    if cfg is None:
        return 2
    sharer = Sharer(cfg)
    if argv[0] in single:
        if len(argv) != 1:
            return _usage("%s は単独で使う" % argv[0])
        sharer.flush_outbox()
        return getattr(sharer, single[argv[0]])()
    if argv[0] == "--print-template":
        from . import templates
        if len(argv) != 2 or "/" in argv[1]:
            return _usage("--print-template には templates/ のファイル名を 1 つ渡す")
        text = templates.load(cfg, argv[1])
        if text is None:
            return _usage("雛形がありません: %s" % argv[1])
        sys.stdout.write(text)
        return 0
    if argv[0] == "--unshare":
        if len(argv) != 2:
            return _usage("--unshare には autonote_id を 1 つ渡す")
        sharer.flush_outbox()
        return sharer.unshare(argv[1])
    if argv[0] == "--recording-deleted":
        undo = len(argv) == 3 and argv[2] == "--undo"
        if not (len(argv) == 2 or undo) or argv[1].startswith("--"):
            return _usage("--recording-deleted には autonote_id を 1 つ渡す（取り消すときは、その後ろに --undo）")
        sharer.flush_outbox()
        return sharer.recording_deleted(argv[1], undo=undo)
    if argv[0].startswith("--"):
        return _usage("知らない引数です: %s" % argv[0])
    path, rest = argv[0], argv[1:]
    opts = {"--kind": None, "--customer": None, "--recording": None, "--recorded-by": None}
    i = 0
    while i < len(rest):
        key = rest[i]
        if key not in opts or i + 1 >= len(rest):
            return _usage("引数が正しくありません: %s" % key)
        if opts[key] is not None:
            return _usage("同じ引数が 2 回あります: %s" % key)
        opts[key] = rest[i + 1]
        i += 2
    if opts["--kind"] not in (None, "internal", "customer"):
        return _usage("--kind は internal か customer")
    if opts["--recorded-by"] is not None and not opts["--recorded-by"].strip():
        return _usage("--recorded-by には呼び名を渡す")
    sharer.flush_outbox()
    return sharer.share_file(path, kind=opts["--kind"], customer=opts["--customer"], recording=opts["--recording"],
                             recorded_by=opts["--recorded-by"])


def main_patrol(argv):
    from .patrol import Patrol
    if argv:
        print("使い方: daily-patrol.sh（引数なし。設定は config.env）", file=sys.stderr)
        return 2
    cfg = _config()
    if cfg is None:
        return 2
    return Patrol(cfg).run()
