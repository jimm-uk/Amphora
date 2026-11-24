---
type: standard
scope: stack-wide
created: 2026-09-17
status: binding — canonical copy; a project's own RESEARCH-STANDARD.md is a working
  copy of this file, not a substitute for it
---

# Research Standard (canonical)

Binding on every task, in every project under `projects/`, whose output carries figures
or sourced claims the user might rely on. A project's `BRIEF.md` says what good output looks
like for that project specifically; this file says how it is enforced everywhere.

It exists because the first batch of research tasks run here (R1-R7, Aug 2026) was
competently sourced and honestly gathered but failed in three specific, recurring ways:
derived numbers were never rechecked, confidence labels were self-awarded without a
basis, and one file padded its table rather than reporting a shortfall. A second failure,
Sep 2026, added a fourth: when this file and its checker went missing from a project
folder, the agent invented a replacement standard, invented a weaker checker, and wrote
into the project that the user had approved the substitution — they had not. Each rule below
traces to a defect that actually occurred. Nothing here is precautionary.

Rules that a model can forget are weak rules. Where possible each requirement is
mechanical — a file either has the section or it does not, the script either runs or it
does not. `tools/research-review/check-research.py` enforces the mechanical subset,
called from a thin per-project shim. A file that does not pass it is not finished.

---

## 0. If this file or the checker is missing from a project, that is not your call

**Rule.** If a project's `RESEARCH-STANDARD.md` or `tools/check-research.py` is absent,
altered, or contradicts this canonical copy, stop the run and say so — in the task's
completion notes and, if the project has one, over the channel the user actually reads. Do
not reconstruct either file from memory, from `TODO.md`, or from a skill file. Do not
proceed "on the assumption the user would approve" and never write that they did approve unless
they told you so in that conversation, verifiably.

**Why.** This is the rule the Sep 2026 failure needed. A missing enforcement file is
either an accident (say so, wait) or deliberate (the user will tell you what changed) — in
neither case does inventing a replacement and self-certifying against it serve them.

## 1. Every derived number comes from a script

Any figure you calculated rather than read — a total, a multiple, a break-even, a
day-rate equivalent, a currency conversion — is produced by a script saved as
`research/calc/<task-id>.py`, actually executed, with its output pasted into the report
verbatim. If a figure has no line in the calc script, delete the figure.

## 2. State a number once, or state it identically

Before finishing, list every figure that recurs in the document and confirm the
instances agree — same value, same units, same basis. Put that list in `## Numbers`.

## 3. Confidence labels must carry their basis, and "agree" must be true

Use `high` / `medium` / `low` / `estimate`, each with a bracketed basis:

| Label | Means |
|---|---|
| `high` | Two or more independent sources, at least one primary, and they agree |
| `medium` | One primary source, or two secondary sources that agree |
| `low` | One secondary source, or a figure inferred from adjacent data |
| `estimate` | Not sourced; the basis for the estimate is stated in the same sentence |

**"Agree" means the raw captures you saved actually contain compatible values for the
claimed field — not that you cited more than one source.** If your own raw captures
disagree with each other (two regional passes recorded different headcounts for the same
company, say), that is a contradiction, not corroboration: label it accordingly and say
so, or drop the higher figure. A label with no basis is not a label.

## 4. Declare the sample frame for any "N of N" claim

Any claim of the form "none of the fourteen...", "all twenty-three...", "the only one I
found..." is followed immediately by a note stating how the set was assembled and what
you would expect to be in it but could not confirm.

## 5. Report the shortfall; never pad to the target

Deliver fewer entries than a target if the evidence supports fewer, and open the file
with one line saying so. Every list task includes a `## Rejected` section: candidates
considered and the specific reason each was dropped. Entries outside the task's
definition go under a separate, clearly-labelled heading and are not counted.

## 6. Length caps are part of the deliverable

Each project's `TODO.md` states a word cap and, for list tasks, a per-entry cap, per
task. Exceeding it is a defect. Depth goes into `research/raw/`, not the report.

## 7. Findings and advice are physically separated

The report body is findings only. Anything telling the user what to do goes in a single
`## Notes for the user` section at the end, or nowhere.

## 8. Required sections, exact headings

```
## Method            — what was searched, what tools, what failed
## Findings          — the substance, findings only
## Numbers           — every derived figure, its calc script line, its repeat check (§2)
## Sample frame      — how the set was assembled, what's missing (list tasks)
## Rejected          — candidates dropped and why (list tasks)
## What is missing   — gaps, blocked sources, half-answers
## Sources           — URL, what it evidenced, date checked
## Notes for the user     — advice, if any (may be empty)
```

## 9. Source freshness is declared where the figure is used

Any source older than three months at the date of the run, or from an archive rather
than live, is marked `[stale: captured <date>]` in the table where its figure appears —
not only in the source list.

## 10. Cross-references must resolve

Every local file a report points at exists at the path given. Deliverable filenames
follow the project's `TODO.md` exactly.

## 11. Raw captures are kept, and cross-checked against each other

For every quoted passage and every figure read off a page, save the extraction to
`research/raw/<task-id>/`. Where the same entity is captured more than once (two regional
or parallel passes finding the same company, say), reconcile them before writing the
final figure — do not silently pick one. `check-research.py` flags this mechanically
where captures are structured data; it cannot catch it in free text, so check by hand
when passes overlap.

## 12. The agent does not mark its own work done

On completion, set status to `review`, never `done`. Only the user sets `done`. Append a
one-line completion note stating what was delivered and what was not — and see §0 before
writing anything about what the user approved.

## 13. Confirm scope before starting

Restate the task, target count, word cap and acceptance criteria in the first lines of
the output file before doing any research.

## 14. Stop at the boundary

Do the tasks marked `ACTIVE`. Do not start a `parked` task. If it looks worth doing, say
so in `## Notes for the user` and stop.

## 15. Findings carrying figures are checked by a profile that did not write them

Per the stack's own standing rule (`etc/profiles/default/SOUL.md`): nothing carrying
figures or sources is signed off by the agent that produced it. A task is not `done`
until a separate reviewer pass — a different invocation, ideally a different model —
has actually run against it and recorded a verdict. "I spot-checked my own six entries"
does not satisfy this.

---

## Acceptance criteria — a task is finished when

1. `tools/check-research.py` passes on the file (it delegates to this canonical copy).
2. Every figure appears in a calc script or is directly quoted from a cited source.
3. Every confidence label states its basis, and no "high" rests on captures that
   disagree with each other.
4. `## Rejected` and `## What is missing` are non-empty, or the file says explicitly why.
5. Entry count and word count are within the task's caps.
6. Status in `TODO.md` is `review`, not `done` — and a separate reviewer pass has run.

## Where the human check goes

The user reviews two things and can skip the rest: the numbers that will reach a client or a
public post, and any claim of the form "none of them" or "the only one".
