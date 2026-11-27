import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sharetorepo.cli import main_patrol  # noqa: E402

sys.exit(main_patrol(sys.argv[1:]))
