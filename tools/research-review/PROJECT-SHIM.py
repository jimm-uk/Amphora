#!/usr/bin/env python3
"""
tools/check-research.py — PROJECT SHIM.

This file is deliberately almost empty. The real checker lives above the mount, at
tools/research-review/check-research.py in the Hermes repo root, where a sandboxed
project agent cannot rewrite it. This shim finds it and calls it.

If this shim reports it cannot find the canonical checker, that is a stack-level
problem: stop and say so. Do not write a replacement checker in this project folder —
see RESEARCH-STANDARD.md §0. Copy this exact file (unmodified) into any project that
needs `tools/check-research.py`.
"""
import subprocess
import sys
from pathlib import Path


def find_canonical():
    here = Path(__file__).resolve()
    # Walk up looking for the repo root's tools/research-review/check-research.py — or,
    # where projects live in a runtime folder outside the checkout, for the
    # .amphora-stack file amphoractl writes at that folder's root, naming the checkout.
    # The walk starts ABOVE the projects folder: the agent can write the project and
    # the projects folder itself, so a checker or pointer planted in either would
    # otherwise be found before the real one.
    project_root = here.parent.parent
    for parent in project_root.parent.parents:
        candidate = parent / "tools" / "research-review" / "check-research.py"
        if candidate.exists() and candidate != here:
            return candidate
        pointer = parent / ".amphora-stack"
        if pointer.is_file():
            stack = Path(pointer.read_text().strip())
            candidate = stack / "tools" / "research-review" / "check-research.py"
            if candidate.exists():
                return candidate
    return None


def main():
    canonical = find_canonical()
    if canonical is None:
        print("FAIL: tools/research-review/check-research.py not found above this "
              "project. This is missing stack infrastructure, not a missing project "
              "file — stop and tell the user rather than writing a replacement here "
              "(RESEARCH-STANDARD.md §0).")
        return 1
    project_root = Path(__file__).resolve().parent.parent
    result = subprocess.run(
        [sys.executable, str(canonical), str(project_root), *sys.argv[1:]],
    )
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
