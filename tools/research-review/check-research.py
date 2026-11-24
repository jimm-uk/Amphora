#!/usr/bin/env python3
"""
check-research.py — canonical enforcement of tools/research-review/RESEARCH-STANDARD.md.

This is the ONE copy that matters. Every project's own `tools/check-research.py` is a
thin shim that imports and calls this file — see PROJECT-SHIM.py in this directory.
If you are reading this because a project's shim is missing or broken: fix the shim,
or ask the user. Do not write a replacement checker inside the project folder. §0 of the
standard exists because that happened once already.

Usage:
    python3 check-research.py <project_root> research/R1.md [research/R2.md ...]
    python3 check-research.py --strict <project_root> research/R5.md

Exit code 0 = all files pass. 1 = at least one FAIL, or the provenance check itself
failed (which is always a FAIL, regardless of --strict).
"""

import json
import os
import re
import sys
from datetime import date, datetime
from pathlib import Path

STANDARD = Path(__file__).resolve().parent / "RESEARCH-STANDARD.md"

REQUIRED_SECTIONS = ["Method", "Numbers", "What is missing", "Sources"]
LIST_TASK_SECTIONS = ["Sample frame", "Rejected"]
CONFIDENCE_WORDS = ["high", "medium", "low", "estimate", "medium-high", "low-medium"]
WORD_CAP_BODY_DEFAULT = 1500
STALE_MONTHS = 3

_ROLE = r"(?:the\s+)?(?:user|requester|operator|owner|reviewer)"

RECONSTRUCTION_PHRASES = [
    r"reconstruct(ed|ion)",
    r"lost from the workspace",
    # Role-based, not name-based. The 2026-09-16 fabrication named a person, and this
    # list matched that one literal spelling — so "the user approved", the identical
    # claim, sailed straight through. Both directions: either reads as governance that
    # never happened.
    rf"{_ROLE}\s+(?:has\s+)?(?:approved|signed off|authoris(?:ed|es)|authoriz(?:ed|es))",
    rf"(?:approved|signed off|authoris(?:ed|es)|authoriz(?:ed|es))\s+by\s+{_ROLE}",
    r"approved proceeding",
    r"restored (?:as|since) the original",
]


# --------------------------------------------------------------------------- §0 ----
def provenance_check():
    """The canonical files must not themselves show signs of having been improvised.
    This guards the guard: if someone edits THIS file to remove the checks below, at
    least the standard's own text still gets scanned for the tell-tale phrases."""
    issues = []
    if not STANDARD.exists():
        issues.append("CANONICAL RESEARCH-STANDARD.md is missing from tools/research-review/ "
                       "— this is a stack-level problem, not a project one. Stop and tell the user.")
        return issues
    text = STANDARD.read_text(encoding="utf-8")
    for pat in RECONSTRUCTION_PHRASES:
        if re.search(pat, text, re.I) and "canonical" not in text[:200].lower():
            issues.append(f"canonical standard contains reconstruction language ('{pat}') "
                           f"— verify this file has not itself been replaced")
    return issues


def _frontmatter_only(text):
    """Return just the YAML frontmatter block (between the first two '---' lines), or
    the whole text if there isn't one. RESEARCH-STANDARD.md's rule body legitimately
    discusses fabricated-approval language at length (it is the rule against doing it)
    so scanning the whole file for these phrases flags its own warning text. The actual
    2026-09-16 fabrication lived in frontmatter metadata (a 'note:' key), so that is
    what gets scanned for that file; TODO.md and report files have no such body-text
    exemption and are scanned in full, since a fabricated completion note in those is
    exactly what standard §0/§12 is watching for."""
    m = re.match(r"^---\s*\n(.*?\n)---\s*\n", text, re.S)
    return m.group(1) if m else text


def project_provenance_check(project_root):
    """Scan a project's own copy of the standard/TODO/report files for the specific
    fabrication pattern seen 2026-09-16: an agent claiming the user approved a substitution
    that never happened. This is a hard FAIL, not a warning — it blocks the run."""
    issues = []
    candidates = list(project_root.glob("RESEARCH-STANDARD.md")) + \
        list(project_root.glob("TODO.md")) + \
        list(project_root.glob("research/*.md"))
    for f in candidates:
        try:
            text = f.read_text(encoding="utf-8")
        except OSError:
            continue
        scan_text = _frontmatter_only(text) if f.name == "RESEARCH-STANDARD.md" else text
        for pat in RECONSTRUCTION_PHRASES:
            m = re.search(pat, scan_text, re.I)
            if m:
                issues.append(
                    f"{f.relative_to(project_root)}: contains '{m.group(0)}' — possible "
                    f"fabricated-governance pattern (standard §0). Do not proceed. Confirm "
                    f"with the user directly before treating this file as legitimate."
                )
    return issues


# ------------------------------------------------------------------- §1-14 core ----
def task_id(path):
    m = re.match(r"(R\d+)", os.path.basename(path))
    return m.group(1) if m else os.path.splitext(os.path.basename(path))[0]


def find_sections(text):
    return [m.group(1).strip() for m in re.finditer(r"^#{2,3}\s+(.+?)\s*$", text, re.M)]


def body_word_count(text):
    out, in_fence, in_sources = [], False, False
    for line in text.splitlines():
        if line.strip().startswith("```"):
            in_fence = not in_fence
            continue
        if re.match(r"^#{2,3}\s+Sources", line, re.I):
            in_sources = True
            continue
        if re.match(r"^#{2,3}\s+", line):
            in_sources = False
        if in_fence or in_sources:
            continue
        if line.strip().startswith("|"):
            continue
        out.append(line)
    return len(" ".join(out).split())


def task_requires_list_sections(project_root, tid):
    """Instead of a hardcoded per-project task table, read the project's own TODO.md:
    if that task's block mentions 'Rejected' or 'Sample frame' as required, enforce it.
    Falls back to False (not required) if TODO.md or the task heading can't be found —
    caller should warn in that case rather than silently passing."""
    todo = project_root / "TODO.md"
    if not todo.exists():
        return None
    text = todo.read_text(encoding="utf-8")
    m = re.search(rf"^##\s*{re.escape(tid)}\b.*?(?=^##\s|\Z)", text, re.S | re.M)
    if not m:
        return None
    block = m.group(0)
    return bool(re.search(r"Rejected.{0,40}required|required.{0,40}Rejected"
                           r"|Sample frame.{0,40}required|required.{0,40}Sample frame",
                           block, re.I)) or "## Rejected" in block


# --------------------------------------------------------------------- §3 / §11 ----
NUMERIC_FIELD = re.compile(r"^\d[\d,.\s]*\+?$|^\d+[-–]\d+$")


NUMERIC_FIELDS = {"headcount", "size", "staff", "employees", "count", "team",
                   "team_size", "price", "rate", "founded", "revenue"}


def _looks_numeric(value):
    """True if a value string is substantially about a count/number (e.g. '~30+',
    '11-50 employees', '16 named staff', '£1,500'), as opposed to free descriptive
    prose. Used to separate real contradictions (two different counts for the same
    thing) from harmless wording differences between two independent researchers
    describing the same company."""
    digits = sum(c.isdigit() for c in value)
    return digits >= 1 and digits / max(len(value), 1) > 0.03 and len(value) < 120


def raw_capture_contradictions(project_root, tid):
    """Cross-reference structured raw captures (research/raw/<tid>/**/*.json) for the
    same named entity appearing more than once with disagreeing values on a field that
    looks like a count or figure. This is what would have caught the Rocketmakers
    headcount case: one regional pass recorded '~30+ (company story page); 16 named
    staff visible', another recorded '11-50 employees (LinkedIn band)' for the same
    company, and the synthesis picked the highest figure and claimed the sources
    agreed. Deliberately narrow: free-text fields (sectors, stack, contact name) differ
    in wording between independent passes as a matter of course and are not flagged as
    failures — only demonstrably numeric disagreement is, because that is the class of
    error that produces a false 'high (...agree)' confidence label. Best-effort — only
    catches entities with an explicit 'name' key in JSON captures; free-text raw
    captures need a human or reviewer pass (standard §11 says so)."""
    raw_dir = project_root / "research" / "raw" / tid
    if not raw_dir.exists():
        return [], []
    seen = {}  # name -> {field: [(value, source_file), ...]}
    for jf in raw_dir.rglob("*.json"):
        try:
            data = json.loads(jf.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        entries = data.get("entries") if isinstance(data, dict) else data
        if not isinstance(entries, list):
            continue
        for e in entries:
            if not isinstance(e, dict) or "name" not in e:
                continue
            name = str(e["name"]).strip().lower()
            seen.setdefault(name, {})
            for k, v in e.items():
                if k in ("name", "sources", "location"):
                    continue
                seen[name].setdefault(k, []).append((str(v)[:200], jf.name))

    fails, warns = [], []
    for name, fields in seen.items():
        for field, vals in fields.items():
            if len(vals) < 2:
                continue
            uniq = {v for v, _ in vals}
            if len(uniq) <= 1:
                continue
            sources = ", ".join(f"{src}: {v[:60]}" for v, src in vals)
            numeric_field = field.lower() in NUMERIC_FIELDS or                 all(_looks_numeric(v) for v, _ in vals)
            msg = (f"raw capture contradiction — '{name}' field '{field}' disagrees "
                   f"across passes ({sources}).")
            if numeric_field:
                fails.append(msg + " A 'high' or claimed-agreement confidence label "
                             "built on this figure is not supported (standard §3).")
            else:
                warns.append(msg + " Likely just wording difference between passes, "
                             "not a factual conflict — worth a glance, not a blocker.")
    return fails, warns


# ------------------------------------------------------------------------- main ----
def check(path, project_root, strict=False):
    fails, warns = [], []
    text = Path(path).read_text(encoding="utf-8")
    tid = task_id(path)
    sections = find_sections(text)
    sec_l = [s.lower() for s in sections]

    for req in REQUIRED_SECTIONS:
        if not any(req.lower() in s for s in sec_l):
            fails.append(f"missing required section '## {req}' (standard §8)")

    list_required = task_requires_list_sections(project_root, tid)
    if list_required is None:
        warns.append(f"could not determine from TODO.md whether {tid} is a list task "
                      f"— §4/§5 sections not checked")
    elif list_required:
        for req in LIST_TASK_SECTIONS:
            if not any(req.lower() in s for s in sec_l):
                fails.append(f"missing '## {req}' — required for list tasks (§4, §5)")

    conf_hits = re.findall(r"confidence", text, re.I)
    if not conf_hits:
        fails.append("no confidence labelling anywhere in the file (§3)")
    else:
        with_basis = re.findall(
            r"\b(?:high|medium|low|estimate|medium-high|low-medium)\b\s*\(", text, re.I)
        bare = len(re.findall(
            r"\bconfidence\b\s*[:|]\s*(?:high|medium|low|estimate|medium-high|low-medium)\b"
            r"\s*(?![\(])", text, re.I))
        if bare and len(with_basis) < bare:
            warns.append(f"{bare} confidence label(s) state a grade with no basis in "
                          f"brackets (§3)")

    notes_start = None
    for m in re.finditer(r"^#{2,3}\s+Notes for the user\s*$", text, re.M | re.I):
        notes_start = m.start()
    body = text[:notes_start] if notes_start is not None else text
    advice = re.findall(
        r"(the user should\b|should be prepared\b|I recommend\b|^\s*\*\*?Recommend"
        r"|Suggested (?:publishing )?order|Recommended \w+ sequence)",
        body, re.I | re.M)
    if advice:
        fails.append(f"{len(advice)} recommendation(s) in the findings body — move to "
                      f"'## Notes for the user' (§7)")

    for ref in set(re.findall(r"`(research/[A-Za-z0-9._/-]+\.(?:md|csv|json|py))`", text)):
        if not (project_root / ref).exists():
            fails.append(f"broken cross-reference: `{ref}` does not exist (§10)")

    if "web.archive.org" in text and not re.search(r"\[stale:", text, re.I):
        fails.append("uses an archived (web.archive.org) source with no '[stale: ...]' "
                      "marker at the point of use (§9)")
    for d in set(re.findall(r"checked\s+(\d{1,2}\s+\w+\s+20\d\d)", text)):
        try:
            when = datetime.strptime(d, "%d %B %Y").date()
        except ValueError:
            continue
        if (date.today() - when).days > STALE_MONTHS * 31:
            warns.append(f"source check date '{d}' is stale (§9)")

    derived = re.search(r"break-?even|equates to|day-rate equivalent|\bx\s+(?:the\s+)?"
                         r"(?:cheapest|multiple)", text, re.I)
    calc = project_root / "research" / "calc" / f"{tid}.py"
    if derived and not calc.exists():
        fails.append(f"file contains derived figures but research/calc/{tid}.py is "
                      f"missing (§1)")

    wc = body_word_count(text)
    cap = WORD_CAP_BODY_DEFAULT
    if wc > cap:
        (fails if strict else warns).append(f"body is {wc} words against a {cap}-word "
                                             f"cap (§6)")

    todo = project_root / "TODO.md"
    if todo.exists():
        t = todo.read_text(encoding="utf-8")
        m = re.search(rf"^##\s*{re.escape(tid)}\b.*?\*\*Status:\*\*\s*`?(\w[\w-]*)`?",
                       t, re.S | re.M)
        if m and m.group(1).lower() == "done":
            warns.append(f"TODO.md marks {tid} as 'done' — the agent should set "
                          f"'review'; only the user sets 'done' (§12)")

    rc_fails, rc_warns = raw_capture_contradictions(project_root, tid)
    fails.extend(rc_fails)
    warns.extend(rc_warns)

    if not re.search(r"reviewer|reviewed by|## verdict", text, re.I):
        warns.append("no trace of an independent reviewer pass in this file — a "
                      "self-graded 'review' status does not satisfy standard §15")

    return fails, warns, wc


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv
    if len(args) < 2:
        print(__doc__)
        return 0

    project_root = Path(args[0]).resolve()
    report_paths = args[1:]

    prov_issues = provenance_check() + project_provenance_check(project_root)
    if prov_issues:
        print("PROVENANCE CHECK FAILED (standard §0) — stopping before any other check.\n")
        for i in prov_issues:
            print(f"   FAIL  {i}")
        print()
        return 1

    worst = 0
    for path in report_paths:
        fails, warns, wc = check(path, project_root, strict)
        status = "FAIL" if fails else ("WARN" if warns else "PASS")
        worst = max(worst, 1 if fails else 0)
        print(f"\n{status}  {os.path.basename(path)}  ({wc} body words)")
        for f in fails:
            print(f"   FAIL  {f}")
        for w in warns:
            print(f"   warn  {w}")
    print()
    return worst


if __name__ == "__main__":
    sys.exit(main())
