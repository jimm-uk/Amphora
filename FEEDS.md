# AI-watch feeds

Why the feed fetcher is wired the way it is, and what it does and does not protect
against. The *how* is in README.md ("AI-watch feeds"); this file is the reasoning and the
threat model.

The requirement: a weekday digest of release announcements from a handful of AI vendors,
plus the day's discussion as AINews summarises it, delivered by email. Feed text is
written by third parties, so it is treated as hostile from the moment it is fetched.

## Shape

```
etc/feeds.csv (gitignored, per checkout)  ─┐
etc/feeds/{Containerfile,fetch.py}        ─┴─ podman build (temp context) ─> amphora-feeds:local

amphora-feeds    amphora-feeds-net alone, no ports, read-only root, no capabilities,
                 no-new-privileges, runs as the Mac's uid, no secrets
  ├─ amphora-feeds-state (volume)    seen ids, held items, per-source counts
  └─ <projects>/ai-watch/inbox (bind)  cleaned batches, status.json

sandbox  /projects/ai-watch/inbox  ─> weekday Hermes job (your own skill) ─> deliver='email'
```

The container fetches every `AMPHORA_FEEDS_INTERVAL` seconds (default three hours). A
fetch writes a batch only when some source has an item it has not reported before. The
agent's scheduled job reads every batch that has arrived since the last digest, so
Monday's covers the weekend, then moves them to `inbox/done/`, writes the digest and
sends it to `AMPHORA_EMAIL_HOME` through the relay. With no batches it sends one line
saying so.

## Why the fetcher is not the agent

The obvious build is a script in `/projects` that the agent runs. It fails on the stack's
rule that whatever enforces a rule on the agent must be out of the agent's reach: an
injected instruction in one feed could tell the agent to add a source, loosen the filter,
or edit the dedup state so an item repeats or vanishes. A read-only mount would need a new
machine share, which can only be added by replacing the machine.

So the fetcher is a container of its own, built like the mail relay. The source list and
the filter are baked into its image from the checkout. Its state lives in a volume that
nothing else mounts, and it is the only thing that touches the network for this job. The
agent receives files and nothing else. Changing a source means editing `etc/feeds.csv`
on the Mac and running `amphoractl feeds push`. The agent can suggest a change, and the
weekly scorecard does, but it cannot make one.

## The guards

In order, from fetch to send. The digest skill is yours to write and is not included here, so
4 and 5 depend on it; the rest are in `etc/feeds/` and `lib/feeds.sh`.

1. **The fetch is fixed.** Only the URLs in the image, over https only. A redirect may
   move within the same host and nowhere else, so a feed cannot bounce the fetcher to a
   host the list never named. Each response is capped at 5 MB and 20 seconds. The model is
   not involved.
2. **The text is cleaned.** HTML becomes text, and scripts, styles and anything hidden
   from a reader are dropped: the `hidden` attribute, `aria-hidden`, `display:none`,
   `visibility:hidden`, zero font size and zero opacity. Hidden text is where an
   instruction aimed at a model rather than a person sits. Then NFKC, and every control,
   format, private-use and unassigned character goes, which covers zero-width, bidi and
   the U+E0000 tag block. These are the relay's subject-line rules. Email addresses are
   replaced, since they appear constantly in co-author lines and nothing the agent sends
   could reach one anyway. Items are capped at 1,500 characters, or 25,000 for the
   zeitgeist tier.

   In the zeitgeist tier, visible links are kept, so each thread of a long issue can point
   at its own source. The text carries a marker, `[L3]`, and the item's `links` maps it to
   the URL. Kept links are https, to a plain ASCII host name, with no login and no
   instruction-like wording. A link in a withheld paragraph, or past the cap, is dropped.
   A marker the feed writes itself is defused.
3. **Suspicious text is quarantined.** Eight pattern rules: instruction overrides, "new
   instructions:", text addressed to a model, role switches, chat-template markup, Hermes
   delivery and tool tokens (`MEDIA:/`, `/mounts/`, `/opt/data`, `deliver=`,
   `cronjob_manage`, `send_message`), shell payloads (`curl … | sh`, `base64 -d`,
   `rm -rf /`) and long encoded blobs.
   - A title that matches holds the whole item.
   - In the body, only the matching paragraph is withheld and replaced by a marker, so a
     long AINews issue that quotes a jailbreak loses one paragraph rather than the day.
   - If more than half the body would go, the item is held whole.

   Held text stays in the state volume. The inbox gets the item's URL and the rule it
   tripped, never the text. `amphoractl feeds held` shows it to a person, with control
   characters stripped twice: once in the container and once on the Mac side of the
   pipe, so a feed cannot write escape sequences to a terminal either.
4. **The data is fenced.** Items reach the model as JSON fields. Your digest skill should
   tell it that a batch is quoted third-party material and never instructions, and that it
   must not open item links.
5. **Links should be checked before sending.** Have the skill run a script that refuses a
   digest containing a URL that is in no batch. Let the model pick a link by its marker, and
   never write a URL. Allowing URLs the model declares itself, from a web search say, weakens
   this to a check on typos: an injected link can be declared too.
6. **Dedup state is out of reach.** The agent cannot replay an item or suppress one;
   only `amphoractl feeds replay`, run from the live checkout, can make the fetcher
   report an item again. A source with no state, whether new or after the volume is
   lost, is seeded silently: its current items count as seen. Each source passes at most 25 new items per run, so a feed
   that renumbers its ids arrives as one capped batch rather than a flood.
7. **The inbox cannot redirect a write.** The agent can write the inbox, so the fetcher
   writes by temp file and rename, opening with `O_NOFOLLOW|O_EXCL`. A rename replaces a
   symlink planted at the destination rather than following it. `start_feeds` refuses
   to bind an inbox that is a symlink, or that has one on the path from the projects
   folder, because podman would resolve it at create. `doctor` checks the same.

Against the live sources the filter holds nothing whole. It withholds a few paragraphs,
mostly `curl … | sh` install lines and release notes that name Hermes' own tools. Those
are exactly the shapes an injection would use, and the item's title and link still go
through. `amphoractl feeds check` reports how many items a candidate source would trip.

## What the guards do not do

**The filter is a pattern list.** An injection written to avoid the patterns passes it,
and from then on the agent is the only judge of the text. Guards 2 and 3 raise the cost of
an attack and catch the common shapes. They are not a boundary.

**The link check stops a misled model, not a hijacked one.** A model that has been talked
into a phishing link includes it and is caught, if the check allows only batch URLs. A model that has been taken over can skip
the check, since the check runs in the sandbox it controls.

**This job cannot be air-gapped.** All projects share one sandbox, and the sandbox has
network. A model taken over while reading a batch could make web requests carrying
whatever it can read, which is everything under `/projects` and `/mounts`, or edit those
files. That exposure exists for every untrusted input the agent reads, a fetched web page
included. The feeds add one more instance of it, behind a filter, rather than a new kind.

**What holds regardless:** the relay delivers only to the allowlist, the agent has no
send tool and no credentials, and it has no route to the Signal daemon, the relay or dind
itself.

## Blast radius

| If this is compromised | Reach |
|---|---|
| A feed or a vendor's publishing account | Text into the agent's context, past the filter if crafted to be. From there, whatever the agent can do: edit `/projects`, make web requests from the sandbox, mislead the digest. It cannot email anyone but the allowlist, add a source, change the filter, or touch dedup state. |
| `amphora-feeds` (a parser exploit) | No secrets, a read-only root, and no network shared with Hermes, dind, Signal or the relay. It can write anything into the inbox, which is the same reach as a feed, and make outbound requests of its own. |
| Agent sandbox | Can delete or forge batches, `used/` records and `status.json`, and skip the link check. Cannot change the source list, the filter or the seen state. |
| The person running `feeds held` / `feeds check` | Sanitised text only. No escape sequences reach the terminal. |
| The digest's reader | The digest arrives from the agent's own mailbox. With a strict link check, it links only to URLs the feeds published, unless the agent itself was taken over. |

## State

What the fetcher writes into the inbox:

- `<stamp>-NN.json`: one batch, with `items` (each with `id`, `url`, `title`,
  `published`, `text`, `source`, `tier`, and `links` in the zeitgeist tier when there are any) and `held` (`source`, `url`, `reason`). Names
  sort in the order they were written.
- `status.json`, rewritten on every fetch: `updated_at`, and per source `ok`, `last_ok`,
  `failing_since`, `error` and the 28-day counts. `seeded` names only the sources seeded
  by *that* fetch, so it is empty on every fetch after a source's first.

`amphora-feeds-state` is not backed up: losing it costs one quiet run, while the seeding
rule rebuilds it. `nuke` removes it without asking. `used/` in the inbox is for the agent's
record of which items made a digest. It feeds the scorecard's "used" column and nothing
else, so a forged one can only skew a suggestion.
