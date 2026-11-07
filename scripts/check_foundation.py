#!/usr/bin/env python3
"""Check the repository's documented foundation without external dependencies."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = (
    "README.md", ".gitignore", "docs/SPEC.md", "docs/ARCHITECTURE.md",
    "docs/DEVELOPMENT_PLAN.md", "docs/PROGRESS.md", "docs/DECISIONS.md",
    ".github/workflows/foundation.yml",
)


def missing_or_empty(root: Path) -> list[str]:
    return [name for name in REQUIRED if not (root / name).is_file()
            or not (root / name).read_text(encoding="utf-8").strip()]


def main() -> int:
    problems = missing_or_empty(ROOT)
    if problems:
        print("Missing or empty foundation files: " + ", ".join(problems), file=sys.stderr)
        return 1
    print(f"Foundation files present and nonempty: {len(REQUIRED)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
