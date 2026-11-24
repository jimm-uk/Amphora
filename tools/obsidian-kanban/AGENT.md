# Rules for Hermes

The Kanban boards in this folder are the only files here you may edit. A script
reconciles them with checklist lines in the vault's tagged notes; these rules exist
because of how that reconciliation works. Each states what breaking it causes.

`Board.md` is the inbox: it is the only board the script adds cards to. On the others it
only ever ticks a card or rewrites a card's title to match its note — it never adds,
moves or deletes a card there — so their arrangement is yours.

A linked card's text belongs to its note, on every board. Anything you add to the title
of a card that has a `[[Note#^t-xxxxxx]]` link is overwritten when the note's line
changes; put notes on an unlinked card instead.

## Never

- **Edit or remove a `^t-xxxxxx` anchor, or a `[[Note#^t-xxxxxx]]` link.** They tie a
  card to one exact line in one note. Remove one and the card is orphaned: the task is
  re-added to `Board.md` as a fresh card and there are then two of everything.
- **Leave a card on two boards, or on none.** A move is one operation — the same line
  removed from one board and added to another. On two boards the script reports the
  clash and stops maintaining it, so it will never tick. On none it looks deleted and
  comes back in the `Board.md` backlog.
- **Touch the `---` block at the top or the `%% kanban:settings %%` block at the
  bottom of any board.** Both belong to the Kanban plugin. Drop either and the file
  stops rendering as a board — and a file that no longer says `kanban-plugin: board`
  stops being read at all, so every card on it looks deleted.
- **Rename, reorder, add or delete a `## Column` heading on an existing board.** The
  columns are the whole vocabulary of a board and nothing else records them; renaming
  one loses what it meant. The settings block also carries one entry per column and is
  not yours to correct.
- **Create or delete a board unless asked to.** When asked to create one, copy the shape
  of an existing board exactly: the `kanban-plugin: board` frontmatter, `## Column`
  headings, and a settings block whose `list-collapse` has one `false` per column.
  A file without that frontmatter is never read, so its cards look deleted. When asked
  to delete one, first move every card to another board: a linked card would come back
  in `Board.md`, and an unlinked one would be gone for good.
- **Delete a card.** One from a note returns on the next sweep; one you created was the
  only copy.
- **Un-tick a card.** Completion moves one way only. Un-ticking does not reopen the
  task, it just makes the two sides disagree until the next sweep re-ticks it.
- **Rewrite a whole board.** Change the lines you mean to change and leave every other
  byte alone. Wholesale regeneration is how anchors and the settings block get lost.
- **Edit any file here that is not a board**, including the `.*.md.bak` backups and `AGENT.md`.

## Do

- **Organise boards when asked:** create, split or merge them, and move cards between
  them, following the rules above.
- **Add a card:** append `- [ ] Some title` under the column you want, on any board. Do
  not invent a `^t-` anchor or a `[[Note#...]]` link for it. A card with no backlink is
  understood to be yours, and the sweep leaves it alone permanently.
- **Move a card, within a board or between boards:** cut the whole line unchanged,
  including its anchor, and paste it under a heading elsewhere. Which board and column a
  card sits in is the boards' alone; nothing about placement is ever written back to the
  note, so a move stays put.
- **Complete a card:** change `- [ ]` to `- [x]`, on whichever board holds it. The sweep
  ticks the matching line in the source note.

## Urgency, impact and due date

Written on the card line, after the title, in exactly this form:

`- [ ] Renew the car insurance, u:1, i:2, d:16/11/26`

- `u:` urgency and `i:` impact, each `1` (high), `2` or `3` (low).
- `d:` due date, day/month/two-digit year. Omit it rather than guess one.
- Any, all or none, in any order. No other spelling: not `urgency:`, `due:`,
  `[impact: high]`, ISO dates or `@{date}`.
- Add them only to cards you created. On a linked card they come from the note, and
  anything you add is overwritten.

## If something looks wrong

Say so and stop. Do not repair it. A board that has lost its settings block, or a card
with a malformed anchor, is recoverable from that board's `.<name>.md.bak` or from Obsidian's version
history — but only while nothing has been written over it.
