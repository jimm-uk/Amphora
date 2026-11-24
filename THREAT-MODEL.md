# Threat model

What Amphora protects, from whom, where the boundaries are, and what is left over. It covers
the whole stack. The component documents go deeper on their own parts and are not repeated
here: [SIGNAL.md](SIGNAL.md), [EMAIL.md](EMAIL.md), [FEEDS.md](FEEDS.md) and
[tools/obsidian-kanban/README.md](tools/obsidian-kanban/README.md).

## Scope and assumptions

In scope: one person running one Amphora deployment on their own Mac, talking to the agent
through the dashboard, the terminal, Signal and email.

Assumed, and outside this model:

- **The Mac and its user account are trusted.** Anything that runs as that user can
  already drive podman, read `etc/amphora.local` and read the snapshots. FileVault is what
  protects data at rest.
- **The upstream projects are not malicious:** Hermes, podman, signal-cli, SearXNG and
  the container images. Their compromise is listed under residual risk, not defended
  against.
- **The model provider behaves as its terms say.** Every prompt and every file the agent
  reads goes to it.

## The central assumption: the agent is untrusted

The agent has terminal access, network access and a model that reads text written by
other people: web pages, email, feeds, documents. Any of that text can carry instructions.
The design therefore treats the agent and its sandbox as the most likely thing to be
compromised. The aim is that a compromised agent can do no more than the agent was
already allowed to do. It must not gain credentials, new recipients, new sources, or a
route to the things that enforce its limits.

## Assets

| Asset | Where it lives | Why it matters |
|---|---|---|
| Hermes state: sessions, memories, skills | `hermes-data` volume; snapshots in `<runtime>/backups/` | A complete record of everything the agent was told |
| Signal identity keys | `amphora-signal-data` volume | Whoever holds them can read and send as the bot. The only state that cannot be rebuilt |
| Credentials: OpenRouter key, dashboard login, mailbox app password | podman secret store, injected as env into `hermes` (and `amphora-mail`) | Spend, dashboard access, the mailbox |
| The Mac's files | The Mac's disk | Only what the machine shares is reachable from the VM |
| The person's other accounts: personal Signal, personal mailbox | Elsewhere | Must not be involved at all |
| Control code and its configuration: `bin/`, `lib/`, `etc/`, `tools/` | The checkout | The code that enforces every limit on the agent |

## Trust boundaries

```
Mac (trusted)
│   checkout, amphora.local, snapshots, launchd jobs ─── never shared with the VM
│
└── podman machine VM ─── sees only the shared folders: projects/, outbox/,
    │                     the vault's Kanban folder, etc/mounts sources
    ├── amphora-dind    privileged; root here is root in the VM
    │   └── sandbox     the agent: unprivileged, the Mac's uid, no sudo, network on
    ├── hermes          unprivileged; holds the secrets and the dind client certs
    ├── amphora-signal  unauthenticated daemon, on amphora-signald-net only
    ├── amphora-signal-relay  the Signal sending allowlist, between it and hermes
    ├── amphora-mail    the sending allowlist, on amphora-mail-net only
    ├── amphora-searxng search, on amphora-net
    └── amphora-feeds   fetcher; no secrets, no network shared with the others
```

The boundaries the design relies on, from the outside in:

1. **Mac ↔ VM: the machine's shares.** Root in the VM can read and write every shared
   folder as the Mac user, so the share list is the reach of any escape. It is narrowed to
   what the stack binds. The checkout, `amphora.local` and the snapshots are never shared,
   and cross by `podman cp` or stdin instead.
2. **VM ↔ dind ↔ sandbox: container isolation.** The sandbox runs unprivileged as the
   Mac's uid, with no sudo or setuid route to root. dind is privileged, so an escape from
   the sandbox into dind is root in the VM. Boundary 1 is what is left after that.
3. **Sandbox ↔ everything else on the VM: networks.** Sandbox traffic leaves through
   dind's interface on `amphora-net`, so anything on `amphora-net` is reachable by IP. The
   Signal daemon and the mail relay therefore sit on networks dind has no interface on.
4. **Agent ↔ files: mounts and the write gate.** The agent sees `/projects` and `/mounts`
   and nothing else of the Mac. The file tools write only under
   `HERMES_WRITE_SAFE_ROOT`. The terminal tool can write anywhere in the sandbox, but the
   sandbox holds only those mounts.
5. **Agent ↔ the world: channels.** Inbound, the gateway admits only allowlisted senders.
   Outbound, there is no `send_message` tool, so the only proactive route is a cron job's
   delivery target, and email from it still has to pass the relay.
6. **Above the mount.** Anything that enforces a rule on the agent, or that launchd runs
   as the Mac user, lives outside every folder the agent can write. That covers the
   control script, the kanban sweep and the research checker.

## Adversaries

| Adversary | Capability | Main entry points |
|---|---|---|
| **Prompt injector** | Writes text the agent will read | Web pages, inbound email, feeds, documents in mounts, a message from an allowlisted account that has itself been compromised |
| **Stranger** | Can message the Signal number or email the mailbox | The gateway's inbound path |
| **Compromised agent** | Arbitrary commands in the sandbox, as the Mac's uid, with network | Everything the sandbox can reach |
| **Container escape** | Code execution in a container beyond the sandbox | dind, hermes, signal-cli, the mail relay, the feed fetcher |
| **Network observer** | Sees traffic between the Mac and the internet | TLS everywhere outbound. The relay verifies STARTTLS |
| **Model provider** | Sees every prompt | By construction |
| **Careless operator** | `git add -A`, `docker system prune`, `podman machine reset` | The checkout, the engine, the volumes |

## Threats and controls

### Inbound messages

| Threat | Control | Checked by |
|---|---|---|
| A stranger drives the agent over Signal | Default-deny `SIGNAL_ALLOWED_USERS`, matched on number and ACI UUID | `doctor` (allowlist set) |
| A stranger drives it through a group | Groups are off unless listed. A listed group still checks each sender against `SIGNAL_ALLOWED_USERS`. `*` is refused, and `platforms.signal.extra.group_allowed_chats`, which would grant the whole group, is never set | `signal_check`, `doctor` |
| A forged From: on email | Upstream refuses mail without DMARC or aligned SPF/DKIM. `AMPHORA_EMAIL_AUTHSERV_ID` pins which `Authentication-Results` header is trusted | `doctor` (IMAP login) |
| Settings inside Hermes replace Amphora's | `/opt/data/.env` overrides the container's environment. `doctor` fails on mailbox, Signal, allowlist, engine or sandbox keys there | `doctor` |

### A compromised or misled agent

| Threat | Control | Checked by |
|---|---|---|
| Reads a credential | `terminal.docker_forward_env: []`. Secrets go only to `hermes` and `amphora-mail`. The `/opt/data` root is not shared into dind, so `.env`, `auth.json` and `state.db` land empty | `doctor` (shared paths) |
| Emails someone new | The relay accepts only recipients on `AMPHORA_EMAIL_ALLOWED`, and only the mailbox's own login and sender. Mail-client skills are disabled | `doctor` (relay session offers a listed recipient and an outsider) |
| Disguises a link in an email | The agent writes plain text or markdown, never markup. The relay's HTML version renders the markdown with raw HTML off, links only `http(s)` URLs and `mailto` to listed addresses, turns images into links, and shows the real host after any link whose text is not exactly its URL, bare look-alike domains included | Construction (`etc/mail/htmlbody.py`) |
| Messages someone new on Signal | The relay passes on messages only to listed people and groups, and only the calls Hermes makes. Neither the sandbox nor Hermes has a route to the daemon | `doctor` (an unlisted number and a forbidden call are refused; addresses probed) |
| Talks to the Signal daemon or the relay directly | Separate networks, membership `hermes` plus that service only | `doctor` |
| Rewrites what enforces its limits | The control script, sweep and research checker live above the mount. The research shim looks for the checker only above the projects folder, so a copy planted in a project is never used | Construction |
| Reaches files beyond what it was given | Mounts come from one list (`etc/mounts`) that writes both hops. `mount add` refuses the checkout, the runtime folder, the snapshots, the outbox, `$HOME` itself and the vault as a whole, after resolving symlinks. Read-only mounts are enforced by the mount itself | `doctor` (reads modes back off the running sandbox) |
| Reads the notes vault | Only `<vault>/Kanban` is bound, plus any vault folder the person adds with `mount add`. A note's checklist reaches the board only if the person tags the note `_TODO`, at note granularity | Tagging and mounting are the person's decisions |
| Gains root | No sudo or setuid in the image. The uid is baked in at build time | Image build |
| Runs code in the Hermes container, beside the secrets and the engine's certs | Toolsets that execute there (`browser`, `connections`, `catalog`, `computer_use`) are disabled. A Hermes release can add another | `doctor` (live config; scripts, hooks, plugins and MCP servers) |
| Reaches the Docker engine | Hermes holds the dind client certs, the sandbox does not | Construction |
| Exfiltrates over the network | **Not prevented.** See residual risk | — |

### Containers and the VM

| Threat | Control | Checked by |
|---|---|---|
| A sandbox escape reaches the Mac | Only the shared folders, which the design narrows to what the stack binds | `doctor` (fails on unshared binds, warns on a share containing home, the checkout or the snapshots) |
| Another container reads Hermes' files | SELinux enforcing in the VM. Hermes runs at a pinned MCS level | `doctor` (ProcessLabel, unreadable files) |
| Something on the Mac drives Amphora's engine by accident | Named connection only. `doctor` fails while `docker.sock` or `DOCKER_HOST` leads to podman | `doctor` |
| A container's environment goes stale | Every change recreates. `doctor` compares the running environment with what the settings would give now | `doctor` |

### Data at rest and in the repository

| Threat | Control | Checked by |
|---|---|---|
| A snapshot is committed to git | The root `.gitignore`, a self-ignoring `backups/.gitignore`, and `doctor` | `doctor` (the only backup finding that fails) |
| Per-machine details are committed | `etc/amphora.local`, `etc/mounts`, `etc/feeds.csv`, `.amphora-stack`, handovers and scratch output are all ignored. Secrets never enter the checkout | `.gitignore` |
| The volumes are deleted | `nuke` prompts. Snapshots, optionally nightly through launchd, are the recovery. `podman machine reset` and `rm` do not prompt | `doctor` (snapshot age) |
| A snapshot drops data silently | Excludes are per-volume. A size check warns when an archive shrinks by half | `backup` |

## If a component is compromised

| Compromised | Reach | Does not reach |
|---|---|---|
| **Agent sandbox** | Everything under `/projects` and `/mounts`, read and write as mounted. The network. Text that Hermes sends to allowlisted recipients | Credentials, the Signal daemon, the relay, the engine, the Mac outside the mounts, vault folders that are not mounted |
| **amphora-dind** | Root in the VM: every container, every volume (Hermes state, Signal keys), and the shared folders as the Mac user | The Mac outside its shares, the checkout, `amphora.local`, the snapshots |
| **hermes** | Every secret, the dind engine (so the same reach as dind, the Signal daemon included), the mailbox directly, around the relay | The same as dind |
| **amphora-signal-relay** | The Signal daemon, and the outbox read-only | Hermes, the agent, the mailbox |
| **amphora-signal** | The bot's Signal identity: read its messages, send as it. The outbox, read-only | Hermes, the agent, the mailbox |
| **amphora-mail** | The mailbox password, any recipient | Hermes' other secrets, the agent |
| **amphora-feeds** | Write into the feed inbox (the same reach as a hostile feed), outbound requests | Secrets, other networks |
| **An allowlisted Signal or email account** | An authenticated injection channel into the agent | Beyond what the agent itself can do |
| **The Signal number's SIM** | Re-registration of the account, subject to its registration PIN | The volume's existing keys |
| **The Mac user account** | Everything | — |

## Residual risk

These are accepted, or not yet addressed. Each one is a reason for care, not a defect
that has been overlooked.

- **Exfiltration from the sandbox.** The sandbox has network so the agent can work. A
  hijacked agent can send anything it can read (`/projects` and `/mounts`) to anywhere.
  `terminal.docker_network: false` would close this and break most work. Mount less, and
  mount `--ro`, where it matters.
- **Some tools still act in the Hermes process.** `skill_manage`, `memory`, `text_to_speech`,
  `web_extract` and cron jobs write or fetch there, within Hermes' own checks. Cron can run
  scripts from `/opt/data/scripts`, where the agent's remaining tools are not known to be able
  to write.
- **Prompt injection from allowlisted channels.** Authentication proves who sent a
  message, not that it is benign. Hermes' approval gate and the sandbox are what stand
  behind it.
- **One sandbox for all projects.** State one project installs is visible to every other.
- **dind is privileged.** A sandbox escape into dind is root in the VM. Narrow shares are
  the mitigation, and they are worth keeping narrow.
- **Hermes holds everything.** A Hermes compromise reaches every secret and the engine.
  The relay limits Hermes' *code*, not a compromised Hermes *process*: only a restriction
  at the mail provider would.
- **The dashboard is guarded by its login alone.** It is published to `127.0.0.1` only,
  but `hermes` is on `amphora-net`, so the sandbox can reach it by IP. Only the login
  stands in the way. Any process on the Mac can reach it too.
- **The model provider sees everything the agent reads.** `provider_routing` with
  `data_collection: deny` excludes hosts that may train on requests. Retention for abuse
  monitoring still applies.
- **Third parties see what the agent looks up.** Searches go out through SearXNG to its
  engines. `web_extract` is unpinned, so a URL the agent reads may be fetched through
  whichever extraction backend Hermes rotates to.
- **Images other than Hermes are pulled by tag, not digest.** An upstream compromise of
  one reaches the stack on the next `update` or `build`. Hermes is pinned by digest, so a
  moved tag cannot change it, but nothing vets a release before you pin it.
- **Skill-declared credential files.** Upstream mounts any file a skill declares in
  `required_credential_files` into the terminal backend. Under this nesting it should
  land empty, which is untested. Verify it before enabling any skill that declares one.
- **Snapshots are plaintext.** They are a full copy of the agent's memory, in the runtime
  folder on the Mac's disk. FileVault and the folder's permissions protect them.
- **Two podman commands delete the volumes without asking:** `podman machine reset` and
  `podman machine rm`. Keep snapshots current.

## Operator responsibilities

The model above holds only if the person running it:

- creates the machine from `amphoractl shares` and never with podman's default shares;
- keeps the allowlists to people they trust, and adds only groups whose members are on
  them;
- gives the agent its own Signal number and its own mailbox, never personal ones;
- tags only notes whose every checklist line may be shown to the agent;
- treats everything the agent can write as the agent's output, not as the stack's own
  documentation or code. That covers `projects/`, the outbox and every mount, including
  the `AGENTS.md` files, skills, scripts and notes there. It is unreviewed work by an
  error-prone author that injected text may have steered. It is never run on the Mac
  outside a container, and never copied above the mount without being read first;
- after a Hermes update, checks for new tools that run outside the sandbox;
- runs `amphoractl doctor` after every change, and treats a red line as a stop;
- keeps the Signal registration PIN and the SIM safe;
- reads a `promote`'s advice and runs what it says.

## Keeping this current

This document describes the stack as it is. A change that adds a container, a network, a
mount, a channel, a credential or a scheduled job moves a boundary and updates this file
in the same commit.
