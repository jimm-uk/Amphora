# Email on a dedicated mailbox

Why the email adapter is wired the way it is. The *how* is in README.md ("Email"); this
file is the reasoning.

The requirement: the agent corresponds with a fixed list of addresses, in both
directions, and with no one else — enforced, not requested.

## The adapter, not a mail client

Upstream offers two unrelated routes to email, and they are not variants of one feature.

The **gateway adapter** makes the agent an address people write to. Hermes polls IMAP for
unseen mail, hands it to the model, and sends over SMTP. It is configured entirely by
process environment, the same shape the Signal adapter already uses.

The **mail-client skills** (`himalaya`, `google-workspace`, and `email-inbox-triage`, which
drives them) make the agent a mailbox owner: a CLI or an OAuth token in the sandbox,
driven by the model, able to write to anyone. Their only guardrail is a sentence in the
skill asking the model to confirm first. They are disabled in `etc/config.yaml`
(`skills.disabled`), because the agent reached for `google-workspace` unprompted the first
time it was asked about email.

## A mailbox of its own

IMAP credentials are whole-mailbox credentials; there is no read-only IMAP and no
per-folder password. An alias or a delegation on a personal account would put every
message in that account inside the container's reach, whatever the allowlist says Hermes
will act on. A separate user costs a seat and gives a separate password, separately
revocable, holding nothing but its own correspondence — the Signal argument, unchanged.

## Inbound: the allowlist, and what upstream already does

`EMAIL_ALLOWED_USERS` is matched exactly, case-insensitively, against the sender. Email is
the one gateway platform whose pairing is off by default, so an unknown sender gets no
reply and no pairing code. `EMAIL_ALLOW_ALL_USERS` and `GATEWAY_ALLOW_ALL_USERS` stay
unset; either one opens the adapter to anyone.

The From header is attacker-controlled, and upstream knows it (advisory
GHSA-rxqh-5572-8m77): unless told otherwise, the adapter trusts a sender only when the
receiving server's `Authentication-Results` shows DMARC pass, or an SPF or DKIM pass
aligned with the From domain. So a forged allowlisted address is dropped by Hermes
itself, not only by the provider's spam filter. Two things sharpen it:

- `AMPHORA_EMAIL_AUTHSERV_ID` pins that check to the provider's own header
  (`mx.google.com` for Google), so a forged `Authentication-Results` smuggled into a
  message cannot be the one it reads.
- A strict DMARC policy on each allowlisted domain still matters — it is what makes a
  forgery fail at the provider before it is ever an inbox message — but it is no longer
  the only thing standing between a forged sender and the agent.

## Outbound: the relay

The adapter addresses mail to whatever `chat_id` it is handed. For a reply that is the
sender, but a scheduled job's `deliver` target is parsed as a bare `platform:chat_id`
with nothing checking it against the allowlist, and the agent composes that target
itself — `cronjob_manage` is in its toolset. So inside Hermes the allowlist governs who
the agent listens to, never who it can write to.

(Upstream does not give the agent `send_message`, the tool that would start a message
directly. That narrows the exposure to scheduled jobs but does not close it, and an
upstream release could change it. The relay means nobody has to keep watch.)

The provider could enforce it, but the setting that restricts correspondence applies to
a whole domain on the edition available, which would restrict the humans on it too. So it
is enforced one layer down instead: `amphora-mail`, a relay of a few hundred lines of
Python on aiosmtpd, is the only SMTP server Hermes knows. It accepts mail only from the
mailbox's own address and credentials, only for recipients on the same list the adapter
listens to, and passes the message on to the provider untouched but for its subject line
and an HTML version of the body (both below). Anything else is
refused at `RCPT TO`, whichever code path produced it — a reply, a scheduled job,
`hermes send`, or whatever a later release adds. One list, both directions, and nothing
to enumerate.

Three consequences follow, all of them simplifications:

- **Hermes is never told the provider's SMTP host.** It is given `mail:2525`; the relay
  holds the real one.
- **The agent can keep a proactive channel.** A scheduled job can only reach the list, so
  it can write to you first — the finished-job notice, the scheduled report, a triage
  asked for on Signal and delivered by mail — and to no one else. Nothing needs
  disabling to make that safe.
- **A Hermes update cannot widen it.** The outbound guarantee does not depend on the
  adapter's behaviour. An update that changed the handshake would fail closed: mail stops
  rather than going somewhere new, and `doctor` says so.

Plain SMTP and AUTH without TLS between Hermes and the relay are deliberate, the same
reasoning as Signal: the relay's network has one other member, and the credential on the
wire is one that member already holds. The relay's leg to the provider is STARTTLS with a
verified certificate.

## Inbound content is untrusted

This is the first channel here whose content is routinely written by someone other than
the person who sent it — a forwarded thread, a quoted reply, a signature, an attachment.
The allowlist authenticates the forwarder, not the text, and Hermes scans context
*files* for prompt injection, not message bodies. SOUL.md is the place to tell the agent
to treat message content as material rather than instructions — a behaviour, which is
what SOUL.md is for — and the sandbox remains the boundary behind that. `platforms.email.skip_attachments` in `config.yaml` (read by the adapter,
absent from the docs) drops inbound attachments entirely if that second parser path is
ever unwanted. The relay changes none of this: it bounds where mail can go, not what an
injected instruction can do inside the sandbox.

## Topology

```
macOS
└── podman machine (rootful)
    ├── hermes          EMAIL_* in its environment; polls IMAP at the provider
    │                   sends only to mail:2525 on amphora-mail-net
    ├── amphora-mail     the relay; recipients from the allowlist, nothing else
    │                   on amphora-mail-net ONLY; outbound STARTTLS to the provider
    ├── amphora-dind     unchanged ── agent sandbox: no EMAIL_*, no route to the relay
    ├── amphora-searxng  unchanged
    └── amphora-signal   unchanged, on its own networks
```

The relay gets its own network for the reason Signal does: if the sandbox could reach it,
the agent would have a sending path that bypasses Hermes. It could still only write to
the list, but a route that does not exist needs no argument. `doctor` fails if dind ever
appears on it.

## Shape of the wiring

- **One switch,** `AMPHORA_EMAIL_ADDRESS`. Unset, no environment reaches Hermes, no secret
  is required, and the relay is removed rather than left running.
- **One secret,** `hermes_email_password`, handed to both containers: Hermes needs it for
  IMAP and to log in to the relay, the relay needs it for the provider. It joins
  `SECRET_MAP` by a conditional append, so a checkout without a mailbox never asks for it.
- **One list,** `AMPHORA_EMAIL_ALLOWED`, handed to both: the adapter as
  `EMAIL_ALLOWED_USERS`, the relay as its recipients. `AMPHORA_EMAIL_HOME`, where scheduled
  output goes, must be on it — `email_check` refuses otherwise, rather than letting the
  relay refuse every scheduled job later.
- **The relay is recreated with Hermes** (`up`, `config push`), because its list is fixed
  in its environment when it is created, exactly like Hermes' own.
- **No subcommand.** `doctor` is the status, and it checks by doing: it logs in over IMAP
  from inside the hermes container, then asks the relay — as Hermes would — to accept one
  listed recipient and one outsider, and resets before DATA, so it proves the enforcement
  live and sends nothing.

Two checks exist for how this goes wrong rather than how it is built. Hermes also reads
`/opt/data/.env`, which its own `hermes setup` and the dashboard's Channels page write; a mailbox configured there would be
a second, unmanaged configuration, a plaintext password in every snapshot, and the one that
wins: Hermes lets that file override the environment Amphora sets.
`doctor` fails on `EMAIL_*`, or on any other setting of ours, in that file, reading key
names only.

## Subject lines

The adapter has no subject setting: it sends "Re:" and the last inbound subject from that
address, or "Re: Hermes Agent". So the relay sets one. If the first line of the body, or
the first line under the gateway's "Cronjob Response" header on scheduled output, is
`[[Subject: ...]]`, `etc/mail/subject.py` removes it and uses the text as the subject,
prefixed `[Amphora]`. With no marker, "Hermes Agent" or "Re: Hermes Agent" becomes
`[Amphora] <date>`. Any other message passes through unchanged, and threading headers are
never touched.

The text is written by the model, so an injected message could steer it. It only ever
reaches the allowlist, and these checks keep it from passing as a link, a reply or a
lure. The text is NFKC-normalised, control and format characters are removed, and the
result must be 3-60 characters. A subject is refused if it contains a link, a domain or
an address, starts with "Re:" or "Fwd:", or contains a lure word such as urgent,
password or verify. A refused marker still has its line removed and gets the dated
subject. The relay logs the reason for the refusal, never the text.

## HTML version

The adapter sends plain text only, so markdown the agent writes would arrive as literal `##`
and `**`. The relay therefore adds an HTML rendering, made by `etc/mail/htmlbody.py`, to
every message with a body: replies, scheduled mail and attachment captions. The plain text
goes first, unchanged; attachments stay where they were; an empty body is left alone.

The parser is markdown-it-py (CommonMark, plus tables, strikethrough and bare-URL linking).
The digests' plain-text conventions are translated first: a line in capitals becomes a
heading, and `- Title (origin): why` with a bare URL beneath it becomes a linked title. A
subject marker's text becomes the page heading, even when the subject checks refused it.

**The model writes markdown, never markup:**

- **Tags** are escaped, because raw HTML is off in the parser.
- **Links** are made only from `http(s)` URLs, and from `mailto` only for an address on the
  allowlist with nothing prefilled. Any other would be a ready-made draft to a stranger.
- **Images** become links, so nothing remote loads. There are no scripts and no external
  stylesheet.
- **The real host** follows every link whose text is not exactly its own URL. Bare URLs are
  included, because the parser shows an internationalised host decoded: `аpple.com` with a
  Cyrillic `а` looks real, and the host shown after it is `xn--pple-43d.com`.

The relay holds the mailbox password, so its packages are installed with `--require-hashes`
from `etc/mail/requirements.txt`, which pins every one to its wheel's sha256. If rendering
fails, the message goes out as plain text and the relay logs why.

## Blast radius

| If this is compromised | Reach |
|---|---|
| Agent sandbox | No credential, no mail client, no route to the relay. It can write text that Hermes sends — to the list, and only the list. |
| `hermes` container | The mailbox's password: reads everything in it, and could send as it by going to the provider directly, around the relay. The relay binds the agent and Hermes' code, not a compromised Hermes process; only a provider-side restriction would. |
| `amphora-mail` container | The same password, and any recipient it chooses. It parses SMTP from one peer only. |
| An allowlisted correspondent's account | An authenticated injection channel into an agent with terminal access. The sandbox, approvals and SOUL.md are what is left. |
| A source in `etc/feeds.csv` | A second inbound text channel, read by a scheduled job rather than addressed to the agent, and screened before it arrives. Its outbound reach is the same list. FEEDS.md. |
| Personal mailbox | Not involved — the agent is a separate user, not an alias or a delegate. |
| Anyone else | Ignored silently inbound; refused at `RCPT TO` outbound. |

## Open

**A PGP/MIME signature cannot be verified, and that is structural.** PGP/MIME signs the
exact raw MIME part bytes; the adapter hands the agent decoded body text with the
`signature.asc` and `publickey` parts cached separately as documents, so the signed bytes
are gone before the model sees them. Every reassembly of the rendered text fails `BAD
signature` no matter how faithful the message was, which reads as tampering and is not.
Nothing here is broken and no key is at fault — the bytes simply do not survive the hop.
Inline PGP (armoured in the body, usually a per-message option in the sender's client) is self-contained and
verifies with `gpg --verify`; that is the workaround, and `gpg` is already in the sandbox.
The failure invites the wrong response: guessing at the plaintext until a check passes.
Tell the agent not to.

**Calendar is undecided.** The adapter is mail only. The obvious route, the
`google-workspace` skill, is the credential-in-the-sandbox design rejected above and is
disabled. Three shapes, none chosen: a host-side sweep in `tools/` in the pattern
`tools/obsidian-kanban/` sets, which puts no credential in the container; invitations
through the mailbox the agent already has; or the skill. The question that settles it is
whether the agent needs to create events or only read them.
