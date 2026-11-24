# Obsidian Kanban

An optional module. A markdown Kanban board lives in the Obsidian vault; tasks are the
unchecked checklist lines of notes tagged `_TODO`; a script reconciles the two in both
directions. The board folder
is the only thing that crosses into the Hermes container, so the agent can read and move
cards without any route to the vault.

Everything is gated on `AMPHORA_VAULT` in `etc/amphora.local`. Unset, nothing is mounted,
nothing runs, and the stack behaves exactly like a checkout that never heard of
Obsidian.

| File | Purpose |
|---|---|
| `kanban-todos.sh` | Entry point: `init`, `run`, `schedule on\|off\|status`. |
| `surface_todos.py` | The sweep. Scans the vault, reconciles it with the board. |
| `Board.template.md` | Skeleton of an empty board. Copied once by `init`, then yours. |
| `AGENT.md` | Rules for the agent. Copied beside the board verbatim on every `init`. |

## Setup

You need [Obsidian](https://obsidian.md) installed first.

1. Install the Kanban plugin in Obsidian (Community plugins → "Kanban").
2. Set `AMPHORA_VAULT` in `etc/amphora.local` to the vault root, e.g.
   `AMPHORA_VAULT="$HOME/Obsidian/MyVault"`.
3. `./tools/obsidian-kanban/kanban-todos.sh init` — creates `<vault>/Kanban/` with the
   board and `AGENT.md`.
4. `./bin/amphoractl up && ./bin/amphoractl doctor`. A container's environment is
   fixed at creation, so the edit does nothing until `up` recreates it.
5. `kanban-todos.sh run --dry-run`, which lists every card it would add and every note
   line it would edit. Then drop the flag.

```bash
./tools/obsidian-kanban/kanban-todos.sh run                  # sweep now
./tools/obsidian-kanban/kanban-todos.sh run --dry-run        # change nothing, say what it would do
./tools/obsidian-kanban/kanban-todos.sh run --no-writeback   # leave notes untouched
./tools/obsidian-kanban/kanban-todos.sh schedule on          # daily LaunchAgent, 08:00
./tools/obsidian-kanban/kanban-todos.sh schedule on --every 30   # or repeating
./tools/obsidian-kanban/kanban-todos.sh schedule status
```

`--at HH:MM` moves the daily schedule and `--every MINUTES` replaces it with a repeating
one; `--overdue-only` narrows either. A LaunchAgent rather than cron, for the reason
`amphoractl backup schedule` uses one: it fires on wake if the Mac was asleep. Output goes
to `logs/todos.log`, each run under a `=== <timestamp>  sweep [flags] ===` header —
including a run that skipped because the vault was missing, which is the one you most
want dated.

`schedule status` answers "is it on and how often" in a line. It reads that back out of
the plist rather than trusting what was last asked for, so it describes what will
actually fire, and it takes "last run" from the run headers. `schedule status -v` adds
the plist and log paths and the whole of the last run. Nothing rotates that log; with a
five-minute sweep it grows steadily, so truncate it when it annoys you.

A repeating sweep is affordable because a run that changes nothing writes nothing — the
board and its backup are touched only when there is something to touch — but every firing
is another attempt at a race that cannot be locked, so five minutes is the floor and
there is no reason to go near it.

`kanban-todos.sh` reads its paths from `etc/amphora.local`; `surface_todos.py` takes them
as arguments if you want to point it elsewhere by hand.

## How the two sides stay in sync

**The anchor is an Obsidian block ID.** The first time a task is surfaced, ` ^t-xxxxxx`
is appended to its line in the note and the card carries `[[Note#^t-xxxxxx]]`. Matching
is by that ID, never by card text, so either side can be reworded without the other
duplicating it. Each card also links to the exact source line, and Obsidian maintains
that link itself when a note is renamed.

**The invariant, from which the rest follows: a card never carries a block ID that its
note does not.** It is why notes are written before the board — a half-finished run then
leaves an ID with no card, which the next run re-adds under the same ID, whereas the
reverse order leaves cards whose IDs no note carries and duplicates them. It is also why
`--no-writeback` reconciles only already-anchored tasks and will not surface a new one.

**The tag marks a note; the checkboxes are the tasks.** Obsidian frontmatter tags whole
notes, not lines, so the sweep works in two stages: a note whose frontmatter carries
`_TODO` is a note holding work, and every unchecked `- [ ]` line inside it is a task.
All three shapes Obsidian writes are understood — a block list, an inline `[a, b]` list,
and a bare scalar — under `tags:` or `tag:`. `--tag NAME` changes which tag is looked
for. A note tagged but holding no checklist is reported, never carded: inventing a card
for it would put something on the board nobody asked for.

New cards always land in the first column. There is deliberately no way to set a card's
column from the note, because a frontmatter tag has no per-task granularity and the only
way to get it would be putting inline tags back into the notes. The board owns
arrangement outright.

**Several boards, one inbox.** Any other Kanban board in the same folder — identified by
its own `kanban-plugin: board` frontmatter, so `AGENT.md` and friends are passed over —
is read on every run. The board named by `--sync` is the only one populated and the only
one the sweep re-renders; the others are patched a line at a time, and only to tick or
retitle a card that is already there.
The agent may create, split, merge or delete boards when asked — that is how boards are
organised over Signal — and `AGENT.md` tells it to copy an existing board's frontmatter
and settings block, since a file without them is never read.

Reading them is what makes moving a card between boards safe. `by_id` is built per board,
so without it a card the agent moved elsewhere looks deleted, is re-added to the inbox on
the next run, and you own two copies — once per move, indefinitely. Ticks travel from any
board back to the note, that direction needing no write to a board the sweep does not
own.

**Other boards get ticks and wording, and nothing else.** A note ticked by hand ticks its
card wherever it lives, and a changed note line retitles it there — which is what lets
the sub-task prefix and a corrected title reach a card the agent has filed away. Nothing
is ever added to, moved on, deleted from or un-ticked on a secondary board, its headings
and settings block are never touched, and a block ID on two boards is reported and left
alone on both. The limits:

- *No re-rendering.* A secondary board is patched through `edit_note`'s guards, not
  `Board.render()`: each target line must still read as it did, and every other line must
  come back byte-identical, so a layout the parser does not fully model (an Archive
  section, plugin settings the inbox never uses) cannot be normalised by a sweep. The
  file is re-read immediately before writing, so edits elsewhere in it survive.
- *One board at a time.* A board whose target line moved or changed is skipped and
  reported; the others are still written, and the next run retries.
- *The race is narrowed, not closed.* The window is the gap between that re-read and
  the atomic replace. Neither the Kanban plugin nor the agent takes a lock, so nothing
  closes it; a lost write is redone by the next run, as on the primary.
- *Card text belongs to the note on every board.* A retitle replaces everything between
  the checkbox and the backlink, so words added to a linked card are lost when its note
  line changes. Annotate the note, or use an unlinked card.
- Each secondary board written gets its own `.<name>.bak`, only when it is written.
- A secondary edit never carries a block ID, so it is applied whether or not
  `--no-writeback` is set, and in either order relative to the notes.

**Ownership is one-directional per field**, so no field is ever fought over:

| Field | Authority | Why |
|---|---|---|
| existence | the notes | The sweep adds cards and never deletes one. |
| wording | the notes | A card whose note line changed is retitled on the board. |
| column | the board | Exclusively. Nothing about placement is ever written back to a note. |
| done | whichever is ticked | Monotonic — ticking either side ticks the other and neither un-ticks, so a missed run cannot resurrect finished work. |

**Optional per-task metadata, written in the note.** A task line may carry any of
`u:` (urgency), `i:` (impact) and `d:` (due), in any order and any combination:

```
- [ ] Renew the car insurance, u:1, i:2, d:16/11/26
```

`u` and `i` run 1 (high) to 3 (low); `d` is day/month/two-digit year. That is the only
spelling — one syntax for notes, boards and the agent, so nothing has to be translated
between them. Each key must start a word (`menu:1` is not urgency) and a comma after a
value is punctuation. Keys rather than positions, so a field can be omitted without
shifting the others, and a comma in the task text — "Sand, fill and paint the banister"
— stays task text. They are copied to the card verbatim, wording being the note's to
own, and they are stripped from a parent's title where it prefixes its sub-tasks.

Only `d` is acted on, by `--overdue-only`; a line without one is never overdue. A date
that is not on the calendar (`d:31/02/26`) is ignored rather than fatal. `u` and `i` are
parsed but drive nothing yet — they ride to the board as text for you and the agent to
read. The Kanban plugin's own `@{date}` is deliberately not used: it cannot be written
in this form, and two spellings of one fact is what this convention replaced.

Checklist lines inside fenced code blocks are ignored, so a note demonstrating the
syntax does not become a pile of cards, and the board's own folder is skipped entirely.
A line with no text after the checkbox is not a task and is dropped rather than carded.

A full vault scan takes about 20ms.

## Safety

**Note edits are narrow and audited.** Only two changes are ever made, and only to
checklist lines inside tagged notes: append a block ID, and flip `[ ]` to `[x]`. Each
queued edit names the exact line text it expects to replace, so a note saved
between the scan and the write — which would shift every index below the insertion — is
skipped rather than edited in the wrong place. Every line not named is then compared
against what was read back, so a bug in the line regexes aborts the file instead of
rewriting it. Writes are atomic.

**Recovery differs by file, deliberately.** Notes rely on the vault's own Obsidian File
Recovery snapshots and Sync history, so no `.bak` files are strewn through the vault.
The boards have no such history and their column placement exists nowhere else, so each
board the sweep writes keeps a `.<name>.bak` — a dotfile, which Obsidian ignores.

**A board that moved underneath is left alone.** Obsidian's Kanban plugin holds its own
copy of an open board and writes it back wholesale on the next drag, so if the file
changed during the scan the sync is abandoned with a message rather than a traceback or
a failure exit. There is no lock behind that check and there cannot be one — a lock binds
only the parties that take it, and the plugin is not ours to change — so the sweep
declines the race whenever it can: a run whose result is byte-for-byte what it read
writes nothing and leaves the backup as it was. Most runs change nothing, so most runs
touch neither file.

**Losing a write is self-healing.** The notes are the source of truth and the sweep is
idempotent, so a card the plugin overwrote comes back. The same contract means a card
deleted from the board without ticking the note off also comes back: tick it in the
note, or let it return.

## What the agent can and cannot see

The vault is **not** mounted. One folder crosses:

```
<vault>/Kanban  ->  dind:/mounts/kanban  ->  sandbox:/mounts/kanban
```

so the agent has no route to any note (unless you add a vault folder with `mount add`), and `etc/` (which holds `amphora.local` and your
phone numbers), `bin/`, `backups/`, `logs/` and `.git/` all sit above the mount and are
unreachable from the sandbox by construction.

But the sweep is itself a channel. **Every checklist line in a note tagged `_TODO` has
its text copied onto the board, and the board is a file the agent reads.** That is the
feature working, not a leak, but it makes the note's tag the decision point — and note
granularity means tagging a note exposes every checklist item in it, not just the ones
you had in mind.

`AGENT.md` in this directory is what the agent is told. `init` copies it beside the
board and overwrites it on every run, so it cannot drift. It is rules only; this file is
the explanation.

## Turning it off, and moving the project

On a machine or VM without the vault, comment out `AMPHORA_VAULT`. That is the whole job:
no bind is created, `run` prints one line and exits 0, and `schedule on` refuses.
Deleting this directory removes the feature entirely — nothing in the stack imports from
here, and `doctor` skips its sweep line when the directory is absent. Scheduling is
launchd, so macOS only; on Linux `schedule` says so and `run` works from any timer.

One artefact cannot live inside the project: the LaunchAgent plist at
`~/Library/LaunchAgents/local.amphora.todos.plist`, because launchd requires an absolute
path. Moving or renaming the checkout strands it, and launchd fails that silently once a
day. It is therefore detected rather than prevented — `amphoractl doctor` fails on it,
`schedule status` reports it in red, and `run` warns — and the fix is always
`kanban-todos.sh schedule on`, which rewrites it.

## Design decisions

**The board lives in the vault**, not in the repo and not in the Hermes volume. Cards
link back to their source notes, and `[[wikilinks]]` resolve only inside the vault
holding the note; Obsidian Sync is per-vault, so a board outside it is also absent from
the phone. A symlink would not help: Obsidian Sync does not handle them.

**Not the Hermes volume.** As the gateway's `kanban.db` it is WAL SQLite that `backup`
must stop Hermes to snapshot, recoverable only by restoring the whole volume, and
unreachable from a chat session anyway (no `kanban_*` tools). As a markdown file it
would be worse: a user document inside a container volume, invisible to Obsidian without
a copy step.

**The module sits above `projects/`**, not inside it. The scheduled sweep runs on the
Mac as you, outside every container; a script in the agent's workspace would be one the
sandboxed agent could rewrite and launchd would then execute unsandboxed. Anything
launchd runs belongs above the mount.

**The bind destination is `/mounts/kanban`**, which `HERMES_WRITE_SAFE_ROOT` already
covers, so the write gate needs no change. `AMPHORA_VAULT_KANBAN` (board
folder) and `AMPHORA_VAULT_BOARD` (file name) override the layout but are inert without
`AMPHORA_VAULT`, so a stale override cannot leave the feature half-on. The source must be
inside a folder the podman machine shares (`amphoractl shares`), or it binds empty with no
error anywhere. `amphoractl up` refuses
that; `doctor` checks what dind can actually see rather than trusting the flag was
passed.

**The notes own what exists; the board owns arrangement.** Checklists stay in context
inside project notes, and the board is the cross-project view only. Neither side deletes
on the other's behalf.

**Sub-tasks carry their ancestors in the card title** — `Roles › Cloud hosting` — because
a board flattens the list and a bare `Cloud hosting` card says nothing about what it
belongs to. Nesting is read from indentation (tabs count as four spaces); a heading,
paragraph or plain top-level bullet ends it, a blank line or indented continuation text
does not. Each ancestor is trimmed for the prefix (no metadata, dates, URLs, `==`, or
trailing colon; 40 characters), and the parent keeps its own card. The prefix is
board-only: the note wins on wording, so editing or re-indenting a parent retitles its
children on the next sweep, and nothing is written back.
