"""Put the repo root and ``lib/`` on ``sys.path`` for the tests.

``strip_workout_hosts`` sits at the repo root and ``monitor_report`` in
``lib/``; both are standalone scripts rather than an installed package, so
their directories have to be on ``sys.path`` before the tests import them.
``focus_policy`` IS a package and is importable from the root.

In the testsAndMisc monorepo a shared conftest did this for several script
directories at once; here there are only these two.
"""

from __future__ import annotations

import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]

for _d in (_ROOT, _ROOT / "lib"):
    if str(_d) not in sys.path:
        sys.path.insert(0, str(_d))
