# Signal on a dedicated number

Why the Signal adapter is wired the way it is. The *how* lives in README.md ("Signal");
this file is the reasoning.

## Why an account of its own

Hermes ships a native Signal adapter, so there is no bridge to write: it talks to a
`signal-cli` daemon over HTTP, SSE for incoming messages and JSON-RPC for outgoing. The
only real decision was which Signal identity the daemon holds, and there are exactly two
shapes.

**It is not linked as a secondary device on a personal number.** That is the easier path
and the one most write-ups take, but it gives the container a full device identity: it decrypts every message on that account into its volume and can send as the
account holder to any contact. The allowlist filters what Hermes *acts on*, not what
signal-cli *sees*. One compromised container is then an impersonation of you to everyone
you have ever messaged.

A dedicated account on a spare SIM costs a number and one registration. In exchange the
daemon only ever holds one identity and only ever sees traffic addressed to it, and the
personal account is not in the blast radius at all.

## Alternatives weighed

| | Why not |
|---|---|
| Matrix (self-hosted Conduit) | No phone number needed and a strong fit for the stack, but E2EE wants libolm and a proxy container on macOS. The runner-up. |
| SimpleX | Best metadata story of any option — no identifiers at all — but no prebuilt image, so simplex-chat has to be built from source. |
| Telegram / Discord bot | Ten minutes' work and no phone number, but not E2EE, and the bot token is an unauthenticated command channel into an agent with terminal access. |
| Tailscale + the API server on 8642 | No third-party identity at all and one credential to protect, but no inbound push, so nothing reaches you unless you open the app. Pairs with the `ntfy` adapter if that changes. |

If Signal ever falls through, Matrix and the Tailscale route are the two to reconsider.

## Topology

```
hermes ── amphora-signal-net ── amphora-signal-relay ── amphora-signald-net ── amphora-signal
          signal-relay:8080      checks every call       signal-cli:8080        signal-cli

amphora-dind and the agent's sandbox: on neither network
```

## Why the daemon gets its own network

The `signal-cli` HTTP interface has no authentication of any kind. Anything that can open a
TCP connection to it can read the bot's messages, send as it, or link a new device to it.

The sandbox's traffic leaves through dind's interface on `amphora-net`, so a sandbox *can*
reach anything else there by IP. The daemon is therefore on a network that only its relay
shares. The isolation is the topology: there is no credential on that port to get wrong,
which is why the network must not be relaxed. `doctor` checks who is on both networks, then
tries the addresses from dind, and the daemon's from Hermes too.

## Who it can write to

In Hermes, the allowlist covers who the agent listens to. A scheduled job may name any
number, and the adapter would send to it. `amphora-signal-relay` (`etc/signal/relay.py`) is
what refuses: a message leaves only for a person on `AMPHORA_SIGNAL_ALLOWED` or a group on
`AMPHORA_SIGNAL_GROUPS`, whichever code path produced it.

- **Only the calls Hermes makes are passed on.** Each is checked parameter by parameter and
  rebuilt, so an alias or a repeated key cannot carry a second recipient. Everything else is
  refused, linking a device included.
- **Account IDs.** Hermes swaps a number for Signal's account ID before sending. The relay
  asks the daemon which number an ID belongs to, and refuses if it cannot tell.
- **Files** come from the outbox only, and a link there is refused.
- **Hermes has no route around it.** Even a compromised Hermes cannot reach the daemon,
  unless it takes the engine's VM first.
- **Incoming messages** pass through untouched. The sender allowlist is still Hermes' job.

Everyone in a listed group sees what is sent there, so list only groups whose members you
trust. A Hermes update that adds a Signal call will have it refused until the relay learns
it: look for `refused:` in `amphoractl logs signal-relay`.

## Decisions taken

**`up` skips the daemon until the account is registered** — a one-line hint, not an error,
and Hermes starts without the Signal environment at all. A checkout on another machine
must never acquire a half-configured messenger. `signal_registered()` answers this by
asking `signal-cli listAccounts`, not by inspecting the volume, because the on-disk layout
is not a stable interface. A running daemon is itself
proof of registration and short-circuits the check, which also keeps it clear of
signal-cli's exclusive account lock.

**The native image.** `signal-cli-native` has no JRE inside, so the Java version pinning
that bites the JVM packaging cannot arise. `AMPHORA_SIGNAL_IMAGE` switches to the `-jre`
build if registration is ever flaky on it.

**Only the official signal-cli daemon.** `bbernhard/signal-cli-rest-api` is the popular
Docker wrapper and is incompatible: different endpoints, different JSON schema. The Hermes
adapter reconnects to it every couple of seconds forever and never receives a message.

## A number that has been registered before

Uninstalling the Signal app does not delete its account, so a spare number may still hold
one. That is fine: `register --reregister` takes it over. If Registration Lock was set, you
need the old PIN at `verify`, though it lapses after seven days of inactivity. If the SMS
does not arrive, `--voice` is an alternative for a number that has passed SMS verification
before.

**`amphoractl signal reset server` deletes the account from Signal's servers** and then wipes
the local state. Signal's documented way to do that is from the app on a handset, which is
not always possible, and Signal Desktop cannot register a primary account. The command is
also the way out of the 409 error a half-finished registration leaves: verified, but never
initialised.

`nuke` asks about `amphora-signal-data` separately. Deleting it destroys the local identity
without deregistering the number, so you would need `--reregister` or `signal reset server`.

## Groups as sessions

Hermes keys a session on the chat, so a Signal group holding you and the bot is a
conversation of its own: its own history, its own `/model`, separate from the DM and from
every other group. That is how to have several chat windows with the agent.

`AMPHORA_SIGNAL_GROUPS` becomes `SIGNAL_GROUP_ALLOWED_USERS`, a list of raw group IDs.
`amphoractl signal groups` maintains it: it asks the running daemon which groups the bot
is in, offers each one not yet listed, writes the line into `etc/amphora.local` and offers
the config push that applies it. Despite the name it filters *groups*, at the adapter:
a group not on it is dropped before the gateway sees it. It grants nothing, because the
Signal platform declares no group-chat grant, so each sender in a listed group is still
matched against `SIGNAL_ALLOWED_USERS`. Someone else added to a listed group is refused
like any stranger. Two settings would change that, and neither is set: `*` in the list,
which `signal_check` refuses because it would answer in any group the bot is added to,
and `platforms.signal.extra.group_allowed_chats` in `config.yaml`, which upstream treats
as a chat-wide grant that skips the sender check. Groups need no @mention
(`require_mention` defaults to false). Replies, `MEDIA:` attachments included, go out
through the same send path as a DM.

## Blast radius

| If this is compromised | Reach |
|---|---|
| Agent sandbox | No route to either Signal network, no Signal identifier in its environment. It can write text that Hermes sends to the lists, and only the lists. |
| `hermes` container | Reads incoming messages and attachments, and writes to the lists. Not to anyone else, unless it uses its hold on the engine to reach the VM. |
| `amphora-signal-relay` container | The daemon, so the bot's identity. It parses requests from Hermes only. |
| `amphora-signal` container | Full use of the bot's identity: read its messages, write as it. Contained to one number that only you message. |
| `amphora-signal-data` volume | The same, and portable — the identity keys can be lifted and used elsewhere. |
| Personal Signal account | Not involved. This is the entire point of the dedicated number. |
| Anyone who messages the bot | Nothing unless allowlisted. Default-deny is the boundary, and the agent has terminal access behind it. |

What is left is the SIM: whoever controls the number controls the account. Keep it as safe as
a hardware key, and set a registration PIN.
