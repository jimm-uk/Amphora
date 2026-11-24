#!/usr/bin/env python3
"""Two-way sync between tagged Obsidian notes and a Kanban board.

Usage:
  surface_todos.py VAULT                            # report only, writes nothing
  surface_todos.py VAULT --sync BOARD.md            # full two-way sync
  surface_todos.py VAULT --sync BOARD.md --dry-run       # say what it would do
  surface_todos.py VAULT --sync BOARD.md --no-writeback  # leave notes untouched
  surface_todos.py VAULT --sync BOARD.md --overdue-only  # only overdue items
  surface_todos.py VAULT --tag NAME                 # default tag is _TODO

A note whose frontmatter carries the tag holds work; every unchecked `- [ ]` line in it
is a task. Cards are anchored to Obsidian block IDs. Other Kanban boards in the same
folder are read, and only ever ticked or retitled line by line: the board named by
--sync is the only one populated. README.md beside this file is the
single description of the design and is where design questions are answered.

The one thing to carry in your head while reading this code: a card never carries a
block ID that its note does not. Notes are therefore written before the board, and
--no-writeback surfaces no new tasks. The comments below mark where that is enforced.
"""

import argparse
import datetime
import os
import signal
import pathlib
import re
import secrets
import shutil
import sys
import tempfile

DEFAULT_TAG = "_TODO"
FRONTMATTER_FENCE_RE = re.compile(r"^---\s*$")
TAGS_KEY_RE = re.compile(r"^(tags?)\s*:\s*(.*)$")
LIST_ITEM_RE = re.compile(r"^\s*-\s*(.+?)\s*$")
# Task metadata: u:1 (urgency), i:2 (impact), d:16/11/26 (due, day first). Each key must
# start a word, so "menu:1" or "http://" is never read as one; a trailing comma is
# punctuation, not part of the value.
META_RE = re.compile(r"(?<![\w:/])([ui]):([1-3])(?!\w)|(?<![\w:/])d:(\d{1,2})/(\d{1,2})/(\d{2})(?![\w/])")
META_STRIP_RE = re.compile(r"[,\s]*(?:%s)" % META_RE.pattern)
BLOCK_ID_RE = re.compile(r"\s\^([A-Za-z0-9][A-Za-z0-9-]*)\s*$")
CHECKBOX_RE = re.compile(r"^(\s*[-*]\s+\[)([ xX])(\]\s+)(.*)$")
CARD_LINK_RE = re.compile(r"\s*\[\[[^\]|]*#\^([A-Za-z0-9][A-Za-z0-9-]*)\]\]\s*$")
HEADING_RE = re.compile(r"^##\s+(.+?)\s*$")
INLINE_CODE_RE = re.compile(r"`[^`]*`")
FENCE_RE = re.compile(r"^\s*(```|~~~)")
URL_RE = re.compile(r"https?://\S+")
MD_LINK_RE = re.compile(r"\[([^\]]*)\]\([^)]*\)")
PARENT_SEP = " › "
PARENT_MAX = 40          # characters kept from each ancestor's title in a child's card
SKIP_DIRS = {".obsidian", ".trash", ".git", "templates"}
TODAY = datetime.date.today()


class SkipFile(RuntimeError):
    """A file that changed underneath us, or an edit that failed its own audit."""


def slug(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def frontmatter_tags(lines):
    """Tags declared in a note's YAML frontmatter, or an empty set.

    A hand parser rather than PyYAML, which is not reliably present on a stock macOS
    python3 and would be a dependency for one key. It handles the three shapes Obsidian
    writes — a block list, an inline list, and a bare scalar — under either `tags:` or
    `tag:`, and ignores everything else in the block.
    """
    if not lines or not FRONTMATTER_FENCE_RE.match(lines[0]):
        return set()
    out = set()
    collecting = False
    for line in lines[1:]:
        if FRONTMATTER_FENCE_RE.match(line):
            break
        m = TAGS_KEY_RE.match(line)
        if m:
            value = m.group(2).strip()
            collecting = value == ""
            if value.startswith("[") and value.endswith("]"):
                value = value[1:-1]
                collecting = False
            for part in value.replace(",", " ").split():
                out.add(part.strip("\"'").lstrip("#"))
            continue
        if collecting:
            item = LIST_ITEM_RE.match(line)
            if item:
                out.add(item.group(1).strip("\"'").lstrip("#"))
                continue
            if line.strip() and not line.startswith((" ", "\t")):
                collecting = False       # a new top-level key ends the list
    out.discard("")
    return out


def parse_meta(line):
    """`u`, `i` and `d` values on a task line, as a dict keyed urgency/impact/due.

    One spelling only: `u:1 i:2 d:16/11/26`, scale 1 (high) to 3 (low), date day first
    with a two-digit year. Order-free, so any can be omitted, and a comma in the task
    text ("Sand, fill and paint") stays task text. Values stay in the card title
    verbatim — the note owns wording.

    A date that matches on shape but not on the calendar (d:31/02/26) is ignored rather
    than raised: one typo in one note must never kill the sweep.

    Only `due` is consumed today (by --overdue-only); urgency and impact are parsed so
    filtering on them is a small change later.
    """
    out = {}
    for key, value, day, month, year in META_RE.findall(line):
        if key:
            out["urgency" if key == "u" else "impact"] = int(value)
            continue
        try:
            out["due"] = datetime.date(2000 + int(year), int(month), int(day))
        except ValueError:
            continue
    return out


def card_title(line):
    """The human part of a task line: no checkbox, no tag, no block ID, no backlink."""
    text = CARD_LINK_RE.sub("", line)
    text = BLOCK_ID_RE.sub("", text)
    m = CHECKBOX_RE.match(text)
    if m:
        text = m.group(4)
    # Empty is empty: a bare "- [ ]" is a line someone has not written yet, and
    # scan_vault drops it rather than putting "(untitled task)" on the board.
    return re.sub(r"\s+", " ", text).strip(" -•\t")


def parent_label(line):
    """A task's title cut down for use as the prefix on its sub-tasks' cards.

    The full title is fine on the parent's own card but repeated on every child it is
    noise, so metadata, dates, URLs, highlight marks and a trailing colon go, and what
    is left is truncated. Only the board sees this — nothing writes it back to a note.
    """
    text = card_title(line)
    text = MD_LINK_RE.sub(r"\1", text)
    text = URL_RE.sub("", text)
    text = META_STRIP_RE.sub("", text)       # with the comma that introduced it
    text = re.sub(r"\s+", " ", text.replace("==", "")).strip(" :-•\t")
    if len(text) > PARENT_MAX:
        text = text[:PARENT_MAX - 1].rstrip() + "…"
    return text


def indent_width(line):
    expanded = line.expandtabs(4)
    return len(expanded) - len(expanded.lstrip())


# --------------------------------------------------------------------- notes --

class Task(object):
    """One checklist line inside a tagged note."""

    __slots__ = ("path", "lineno", "line", "title", "block_id", "checked", "overdue",
                 "meta")

    def __init__(self, path, lineno, line, ancestors=()):
        self.path = path
        self.lineno = lineno
        self.line = line
        # Sub-tasks carry their ancestors' titles, so a card read on its own still says
        # what it belongs to: "People Per Hour Jobs/Roles › Cloud hosting".
        self.title = PARENT_SEP.join(list(ancestors) + [card_title(line)])
        m = BLOCK_ID_RE.search(line)
        self.block_id = m.group(1) if m else None
        m = CHECKBOX_RE.match(line)
        self.checked = bool(m and m.group(2) in "xX")
        self.meta = parse_meta(line)
        self.overdue = "due" in self.meta and self.meta["due"] < TODAY


def scan_vault(vault, board_path, tag=DEFAULT_TAG):
    """Checklist lines in notes whose frontmatter carries the tag.

    Two stages, because the tag is a note property rather than something on the task
    line: the frontmatter says which notes hold work, and the `- [ ]` lines inside them
    say what the work is. A note tagged but holding no checklist is returned separately
    so it can be reported rather than silently ignored.

    Checked lines are collected too, not just open ones — a line ticked in the note has
    to be able to tick its card.

    Fenced code blocks are skipped, so a note demonstrating checklist syntax does not
    become a pile of cards. The board's own folder is skipped for the same reason.
    """
    board_dir = board_path.parent.resolve() if board_path is not None else None
    tasks, empty_notes = [], []
    for md in sorted(vault.rglob("*.md")):
        if any(part in SKIP_DIRS for part in md.parts):
            continue
        if board_dir is not None and md.resolve().parent == board_dir:
            continue
        try:
            lines = md.read_text(encoding="utf-8").splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        if tag not in frontmatter_tags(lines):
            continue
        found = 0
        fenced = False
        stack = []            # (indent, label) for each open checkbox ancestor
        for i, line in enumerate(lines):
            if FENCE_RE.match(line):
                fenced = not fenced
                stack = []
                continue
            if fenced:
                continue
            if CHECKBOX_RE.match(line):
                width = indent_width(line)
                while stack and stack[-1][0] >= width:
                    stack.pop()
                if card_title(line):
                    tasks.append(Task(md, i, line, [lbl for _, lbl in stack]))
                    found += 1
                label = parent_label(line)
                if label:
                    stack.append((width, label))
            elif line.strip() and not line[:1].isspace():
                # A heading, paragraph, rule or plain top-level bullet ends the list.
                # Blank lines and indented continuation text do not.
                stack = []
        if not found:
            empty_notes.append(md)
    return tasks, empty_notes


def edit_note(path, edits, dry_run, backup=False):
    """Apply {line index: (line as scanned, replacement)} to one file, or write nothing.

    Used for notes, and for boards other than the primary, which the sweep patches line
    by line rather than re-rendering (see patch_boards). `backup` keeps a dotfile copy
    beside the file first, for boards, which have no Obsidian history behind them.

    Two guards, and the first is the one that matters. Edits are worked out from what
    the scan read, but the file is re-read here — so if you saved the note in between,
    an inserted line would shift every index below it and we would rewrite the wrong
    line. Each edit therefore names the exact text it expects to find, and a mismatch
    abandons the whole file rather than guessing where the line went.

    The second guard is a full audit: every line not named in the edit map is compared
    against what was read back, so a bug in the line-editing regexes cannot quietly
    rewrite a note either.
    """
    if not edits:
        return
    original = path.read_text(encoding="utf-8")
    keep_final_newline = original.endswith("\n")
    lines = original.splitlines()
    out = list(lines)
    for idx, (expect, new_line) in edits.items():
        if idx >= len(out):
            raise SkipFile("%s is shorter than when it was scanned — skipped" % path.name)
        if out[idx] != expect:
            raise SkipFile("%s changed since it was scanned — skipped, run again"
                           % path.name)
        out[idx] = new_line
    for i, (before, after) in enumerate(zip(lines, out)):
        if i not in edits and before != after:
            raise SkipFile("refusing to write %s: line %d changed but was not meant to"
                           % (path.name, i + 1))
    if dry_run:
        return
    text = "\n".join(out) + ("\n" if keep_final_newline else "")
    if backup:
        shutil.copy2(path, path.with_name("." + path.name + ".bak"))
    replace_atomically(path, text)


def set_block_id(line, block_id):
    return line.rstrip() + " ^" + block_id


def set_title(line, title, note_stem, block_id):
    """A card line with its title replaced; box, tick state and backlink kept."""
    m = CHECKBOX_RE.match(line)
    return "%s%s%s%s [[%s#^%s]]" % (m.group(1), m.group(2), m.group(3), title,
                                    note_stem, block_id)


def set_checked(line):
    m = CHECKBOX_RE.match(line)
    if not m or m.group(2) in "xX":
        return line
    return m.group(1) + "x" + m.group(3) + m.group(4)


# --------------------------------------------------------------------- board --

class Board(object):
    """A Kanban board as header, ordered columns of card lines, and footer.

    Cards are only ever appended or ticked. Columns are never reordered and existing
    cards are never moved, so the board stays yours to curate — the sweep's job is to
    make sure nothing is missing from it, not to arrange it.
    """

    def __init__(self, path):
        self.path = path
        self.mtime = path.stat().st_mtime
        text = path.read_text(encoding="utf-8")
        self.original = text
        self.trailing_newline = text.endswith("\n")
        self.header, self.columns, self.footer = [], [], []
        self.lineno = {}      # (id of column list, index) -> line index in the file
        current = None
        in_footer = False
        for n, line in enumerate(text.splitlines()):
            if in_footer:
                self.footer.append(line)
            elif line.startswith("%%"):
                in_footer = True
                self.footer.append(line)
            else:
                m = HEADING_RE.match(line)
                if m:
                    current = (m.group(1), [])
                    self.columns.append(current)
                elif current is None:
                    self.header.append(line)
                else:
                    self.lineno[(id(current[1]), len(current[1]))] = n
                    current[1].append(line)
        if not self.columns:
            raise SkipFile("%s has no '## Column' headings — is it a Kanban board?"
                           % path)

    @property
    def default_column(self):
        return self.columns[0][0]

    def cards(self):
        """(column name, index within column, checked, block id) for every card."""
        for name, lines in self.columns:
            for i, line in enumerate(lines):
                m = CHECKBOX_RE.match(line)
                if not m:
                    continue
                link = CARD_LINK_RE.search(m.group(4))
                yield name, i, m.group(2) in "xX", (link.group(1) if link else None)

    def card_line(self, column_name, index):
        """(line index in the file, line) for a card, as read."""
        _, lines = self.column(column_name)
        return self.lineno[(id(lines), index)], lines[index]

    def column(self, name):
        for cname, lines in self.columns:
            if slug(cname) == slug(name):
                return cname, lines
        return None, None

    def add(self, column_name, title, note_stem, block_id):
        cname, lines = self.column(column_name)
        if lines is None:
            cname, lines = self.columns[0]
        card = "- [ ] %s [[%s#^%s]]" % (title, note_stem, block_id)
        # A blank line between heading and first card, so an empty column still reads
        # as markdown to anything that is not the Kanban plugin.
        while lines and not lines[-1].strip():
            lines.pop()
        if not lines:
            lines.append("")
        lines.append(card)
        return cname

    def set_card(self, column_name, index, line):
        _, lines = self.column(column_name)
        lines[index] = line

    def render(self):
        parts = list(self.header)
        for name, lines in self.columns:
            parts.append("## " + name)
            parts.extend(lines)
            if not lines or lines[-1].strip():
                parts.append("")
        parts.extend(self.footer)
        return "\n".join(parts) + ("\n" if self.trailing_newline else "")

    def save(self, dry_run):
        if dry_run:
            return
        # A run that would put back exactly what it read writes nothing at all. There is
        # no lock against the Kanban plugin and there cannot be one — a lock binds only
        # the parties that take it, and the plugin is not ours to change — so every write
        # is a race, and this one would win nothing while copying the current board over
        # the only backup. Most runs change nothing, so most runs now touch neither file.
        rendered = self.render()
        if rendered == self.original:
            return
        if self.path.stat().st_mtime != self.mtime:
            raise SkipFile("the board changed while the vault was being scanned — "
                           "nothing written. Close it in Obsidian, or run again.")
        # The board is the one file here with no Obsidian history behind it, and column
        # placement exists nowhere else, so it keeps a backup.
        # A dotfile: Obsidian ignores those, so the backup stays out of the file
        # explorer, out of search and out of Sync, while still sitting beside the board.
        shutil.copy2(self.path, self.path.with_name("." + self.path.name + ".bak"))
        replace_atomically(self.path, rendered)


def replace_atomically(path, text):
    """Replace a file, or leave it exactly as it was.

    A plain read-modify-write truncates the file if the process dies or the disk fills
    partway through.
    """
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix="." + path.name + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def sibling_boards(board_path):
    """Every other Kanban board in the primary board's folder.

    The sweep populates the primary board only. The rest are read, and patched only to
    tick or retitle a card (patch_boards). Reading them is what stops a card the agent
    moved to another board from looking deleted — `by_id` is per-board, so without
    this the next run re-adds it to the inbox and you own two copies.

    A board is identified by its own frontmatter (`kanban-plugin: board`), not by
    filename, so AGENT.md and anything else in the folder is passed over.
    """
    out = []
    for md in sorted(board_path.parent.glob("*.md")):
        if md.resolve() == board_path.resolve():
            continue
        try:
            head = md.read_text(encoding="utf-8").split("\n", 20)
        except (UnicodeDecodeError, OSError):
            continue
        if not any(line.strip() == "kanban-plugin: board" for line in head[:20]):
            continue
        try:
            out.append(Board(md))
        except (SkipFile, OSError):
            continue                  # not a usable board; not our problem to fix
    return out


class Elsewhere(object):
    """Where a card sits on a board other than the primary."""

    __slots__ = ("board", "column", "index", "checked", "copied")

    def __init__(self, board, column, index, checked):
        self.board, self.column, self.index = board, column, index
        self.checked = checked
        self.copied = False           # also on another secondary board: never patched

    @property
    def name(self):
        return self.board.path.name


def cards_elsewhere(boards, log):
    """block ID -> Elsewhere, for cards on boards other than the primary."""
    out = {}
    for b in boards:
        for column, index, checked, block_id in b.cards():
            if not block_id:
                continue
            if block_id in out:
                log("  ! ^%s is on both %s and %s — left alone"
                    % (block_id, out[block_id].name, b.path.name))
                out[block_id].copied = True
                continue
            out[block_id] = Elsewhere(b, column, index, checked)
    return out


def patch_boards(edits, dry_run, log):
    """Apply {board path: {line index: (line as read, replacement)}}. Returns skips.

    Secondary boards are the agent's and yours to arrange, so they are never
    re-rendered: only the named card lines change, through the same two guards as a
    note edit — each line must still read as it did, and every other line must come
    back byte-identical — so a board layout this parser does not fully understand is
    left as it was rather than normalised. The file is re-read immediately before the
    write, which narrows the race with the Kanban plugin and the agent to that gap;
    nothing closes it, since neither takes a lock.

    One board failing its guards is skipped on its own; the rest are still written.
    """
    skipped = 0
    for path, board_edits in sorted(edits.items()):
        try:
            edit_note(path, board_edits, dry_run, backup=True)
        except SkipFile as exc:
            skipped += 1
            log("  ! %s" % exc)
            continue
        if dry_run:
            for idx, (_, new_line) in sorted(board_edits.items()):
                log("  ~ %s:%d  %s" % (path.name, idx + 1, new_line.strip()))
    return skipped


# ----------------------------------------------------------------- reconcile --

def reconcile(tasks, board, elsewhere, overdue_only, writeback, dry_run, log):
    """Work out every edit, then apply them. Returns a counts dict."""
    counts = dict(added=0, retitled=0, ticked_card=0, ticked_note=0,
                  stamped=0, orphans=0, stale=0, dupes=0, needs_note=0,
                  skipped=0, elsewhere=0, ticked_elsewhere=0,
                  retitled_elsewhere=0, boards_skipped=0)
    by_id = {}
    for column, index, checked, block_id in board.cards():
        if block_id:
            by_id[block_id] = (column, index, checked)

    note_edits = {}          # path -> {line index: (line as scanned, replacement)}
    board_edits = {}         # secondary board path -> the same shape
    fresh_ids = set(by_id)   # guards against a collision with an ID already in use

    def stage(task, transform):
        """Queue one edit, keeping the as-scanned line as the thing it must match.

        Several edits can land on one line in a single pass (a stamp and a tag rewrite,
        say), so each builds on the previous replacement while the expected original
        stays fixed.
        """
        slot = note_edits.setdefault(task.path, {})
        expect, current = slot.get(task.lineno, (task.line, task.line))
        slot[task.lineno] = (expect, transform(current))

    seen_ids = set()
    for task in tasks:
        if task.block_id:
            if task.block_id in seen_ids:
                counts["dupes"] += 1
                log("  ! duplicate block ID ^%s at %s:%d — copied line? left alone"
                    % (task.block_id, task.path.name, task.lineno + 1))
                continue
            seen_ids.add(task.block_id)
        if task.block_id and task.block_id in by_id:
            # Copied rather than moved: still here and also on another board. Only the
            # board this run writes is maintained, so say which copy is going stale.
            if task.block_id in elsewhere:
                counts["dupes"] += 1
                log("  ! ^%s is on both %s and %s — only the %s card is maintained"
                    % (task.block_id, board.path.name, elsewhere[task.block_id][0],
                       board.path.name))
            column, index, card_checked = by_id.pop(task.block_id)
            _, lines = board.column(column)
            line = lines[index]

            # done: whichever side is ticked wins, and neither ever un-ticks.
            if card_checked and not task.checked:
                stage(task, set_checked)
                counts["ticked_note"] += 1
            elif task.checked and not card_checked:
                board.set_card(column, index, set_checked(line))
                counts["ticked_card"] += 1

            # wording: the note wins.
            if card_title(lines[index]) != task.title:
                board.set_card(column, index, set_title(
                    lines[index], task.title, task.path.stem, task.block_id))
                counts["retitled"] += 1

            # No column writeback. A frontmatter tag marks the note, not the line, so
            # there is nowhere per-task to record status without putting inline tags
            # back into the notes. The board simply owns arrangement.
            continue

        if task.block_id and task.block_id in elsewhere:
            # The card was moved to another board. It exists, so it is not re-added.
            # Ticks and wording still reach it, but nothing else does: no card is added,
            # moved, deleted or un-ticked on a secondary board, and a card copied onto
            # two of them is left alone.
            where = elsewhere[task.block_id]
            counts["elsewhere"] += 1
            if where.checked and not task.checked:
                stage(task, set_checked)
                counts["ticked_note"] += 1
            if where.copied:
                continue
            lineno, line = where.board.card_line(where.column, where.index)
            new = line
            if task.checked and not where.checked:
                new = set_checked(new)
                counts["ticked_elsewhere"] += 1
            if card_title(new) != task.title:
                new = set_title(new, task.title, task.path.stem, task.block_id)
                counts["retitled_elsewhere"] += 1
            if new != line:
                board_edits.setdefault(where.board.path, {})[lineno] = (line, new)
            continue

        if task.checked:
            continue                       # finished, and never carded. Stays quiet.
        if overdue_only and not task.overdue:
            continue
        if task.block_id and task.block_id not in by_id:
            counts["orphans"] += 1         # carded once, card since deleted by hand

        block_id = task.block_id
        if not block_id:
            # The invariant that keeps this safe: a card never carries an ID the note
            # does not. Surfacing a new task needs a note edit, so with --no-writeback
            # it is left alone rather than carded — otherwise the next run finds no ID
            # in the note, stamps a fresh one, and adds the card a second time.
            if not writeback:
                counts["needs_note"] += 1
                continue
            while True:
                block_id = "t-" + secrets.token_hex(3)
                if block_id not in fresh_ids:
                    break
            fresh_ids.add(block_id)
            stage(task, lambda ln, b=block_id: set_block_id(ln, b))
            counts["stamped"] += 1

        where = board.add(board.default_column, task.title, task.path.stem, block_id)
        counts["added"] += 1
        log("  + %-12s %s" % (where, task.title))

    counts["stale"] = len(by_id)

    # Order does not matter here, unlike the primary: a secondary edit only ticks or
    # retitles, never carries a new block ID, so either half failing alone is repaired
    # by the next run. Done regardless of --no-writeback, which protects notes only.
    counts["boards_skipped"] = patch_boards(board_edits, dry_run, log)

    if not writeback:
        withheld = sum(len(e) for e in note_edits.values())
        if withheld or counts["needs_note"]:
            log("  (--no-writeback: %d note edit(s) withheld, %d new task(s) not "
                "surfaced)" % (withheld, counts["needs_note"]))
        return counts

    for path, edits in sorted(note_edits.items()):
        try:
            edit_note(path, edits, dry_run)
        except SkipFile as exc:
            counts["skipped"] += 1
            log("  ! %s" % exc)
            continue
        if dry_run:
            for idx, (_, new_line) in sorted(edits.items()):
                log("  ~ %s:%d  %s" % (path.name, idx + 1, new_line.strip()))
    return counts


def report(tasks, empty_notes, vault, tag):
    live = [t for t in tasks if not t.checked]
    for t in live:
        flag = "  OVERDUE" if t.overdue else ""
        print("%s:%d  %s%s" % (t.path.relative_to(vault), t.lineno + 1, t.title, flag))
    if live:
        print("\n%d open item(s), %d overdue." % (len(live), sum(t.overdue for t in live)))
    else:
        print("No open checklist items in notes tagged %s." % tag)
    # Reported, never carded: a tagged note with nothing to do in it is usually a note
    # that has been finished or one where the checklist has not been written yet, and
    # inventing a card for it would put something on the board nobody asked for.
    if empty_notes:
        print("\n%d note(s) tagged %s with no checklist items:" % (len(empty_notes), tag))
        for md in empty_notes[:10]:
            print("  %s" % md.relative_to(vault))
        if len(empty_notes) > 10:
            print("  ... and %d more" % (len(empty_notes) - 10))


def main():
    # Die quietly on `| head` instead of printing a BrokenPipeError traceback that
    # looks like a failure in a log.
    try:
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    except (AttributeError, ValueError):
        pass
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("vault", type=pathlib.Path)
    ap.add_argument("--sync", type=pathlib.Path, metavar="BOARD.md")
    ap.add_argument("--overdue-only", action="store_true")
    ap.add_argument("--dry-run", action="store_true",
                    help="print every edit to the board and to notes, write nothing")
    ap.add_argument("--no-writeback", dest="writeback", action="store_false",
                    help="never modify notes; the board is updated but nothing flows back")
    ap.add_argument("--tag", default=DEFAULT_TAG, metavar="NAME",
                    help="frontmatter tag marking a note as holding tasks "
                         "(default: %s)" % DEFAULT_TAG)
    args = ap.parse_args()

    vault = args.vault.resolve()
    if not vault.is_dir():
        sys.exit("Not a directory: %s" % vault)
    board_path = args.sync.resolve() if args.sync else None
    if board_path is not None and not board_path.is_file():
        sys.exit("Board file not found: %s" % board_path)

    tasks, empty_notes = scan_vault(vault, board_path, args.tag)
    report(tasks, empty_notes, vault, args.tag)
    if board_path is None:
        return 0

    try:
        board = Board(board_path)
    except SkipFile as exc:
        sys.exit(str(exc))

    print("\nSync%s:" % (" (dry run)" if args.dry_run else ""))
    try:
        others = sibling_boards(board_path)
        if others:
            print("  reading %d other board(s): %s"
                  % (len(others), ", ".join(b.path.name for b in others)))
        counts = reconcile(tasks, board, cards_elsewhere(others, print),
                           args.overdue_only, args.writeback, args.dry_run, print)
        board.save(args.dry_run)
    except SkipFile as exc:
        # Not worth a traceback, and not worth failing a scheduled run over: the sweep
        # is idempotent, so the next one picks up whatever this one put down.
        print("  skipped: %s" % exc)
        return 0

    print("  %d added, %d retitled, %d card(s) ticked, %d note(s) ticked, "
          "%d stamped" %
          (counts["added"], counts["retitled"], counts["ticked_card"],
           counts["ticked_note"], counts["stamped"]))
    if counts["elsewhere"]:
        print("  %d card(s) live on another board — not re-added here" %
              counts["elsewhere"])
    if counts["ticked_elsewhere"] or counts["retitled_elsewhere"]:
        print("  on other boards: %d card(s) ticked, %d retitled" %
              (counts["ticked_elsewhere"], counts["retitled_elsewhere"]))
    if counts["boards_skipped"]:
        print("  %d other board(s) changed during the run — skipped, run again" %
              counts["boards_skipped"])
    if counts["orphans"]:
        print("  %d task(s) had their card deleted by hand — re-added" %
              counts["orphans"])
    if counts["stale"]:
        print("  %d card(s) no longer have a checklist line behind them — left in place" %
              counts["stale"])
    if counts["dupes"]:
        print("  %d duplicated block ID(s) — see above" % counts["dupes"])
    if counts["skipped"]:
        print("  %d note(s) skipped; run again" % counts["skipped"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
