import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sharetorepo.cli import main_share  # noqa: E402

sys.exit(main_share(sys.argv[1:]))
