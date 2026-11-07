import tempfile
import unittest
from pathlib import Path

from scripts.check_foundation import REQUIRED, missing_or_empty


class FoundationCheckTests(unittest.TestCase):
    def test_reports_missing_and_empty_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in REQUIRED:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("content", encoding="utf-8")
            self.assertEqual(missing_or_empty(root), [])
            (root / REQUIRED[0]).write_text("  \n", encoding="utf-8")
            (root / REQUIRED[1]).unlink()
            self.assertEqual(missing_or_empty(root), list(REQUIRED[:2]))


if __name__ == "__main__":
    unittest.main()
