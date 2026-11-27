"""Command lines of share-meeting.sh and daily-patrol.sh."""
import sys

from .config import Config

SHARE_USAGE = """使い方:
  share-meeting.sh <会議ファイル> [--kind internal|customer] [--customer <相手先>] [--recording <録画のファイル名>]
  share-meeting.sh --unshare <autonote_id>
  share-meeting.sh --retry-pending
  share-meeting.sh --rebuild-index
  share-meeting.sh --rebuild-mirror"""


def _usage(msg=None):
    if msg:
        print(msg, file=sys.stderr)
    print(SHARE_USAGE, file=sys.stderr)
    return 2


def main_share(argv):
    from .share import Sharer
    if not argv or argv[0] in ("-h", "--help"):
        return _usage() if not argv else (print(SHARE_USAGE) or 0)
    single = {"--retry-pending": "retry_pending", "--rebuild-index": "rebuild_index",
              "--rebuild-mirror": "rebuild_mirror"}
    cfg = Config()
    sharer = Sharer(cfg)
    if argv[0] in single:
        if len(argv) != 1:
            return _usage("%s は単独で使う" % argv[0])
        sharer.flush_outbox()
        return getattr(sharer, single[argv[0]])()
    if argv[0] == "--unshare":
        if len(argv) != 2:
            return _usage("--unshare には autonote_id を 1 つ渡す")
        sharer.flush_outbox()
        return sharer.unshare(argv[1])
    if argv[0].startswith("--"):
        return _usage("知らない引数です: %s" % argv[0])
    path, rest = argv[0], argv[1:]
    opts = {"--kind": None, "--customer": None, "--recording": None}
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
    sharer.flush_outbox()
    return sharer.share_file(path, kind=opts["--kind"], customer=opts["--customer"], recording=opts["--recording"])


def main_patrol(argv):
    from .patrol import Patrol
    if argv:
        print("使い方: daily-patrol.sh（引数なし。設定は config.env）", file=sys.stderr)
        return 2
    return Patrol(Config()).run()
