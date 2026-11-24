"""Outbound mail relay for the Hermes email adapter.

Hermes sends through this relay, never straight to the provider. It accepts mail only from the
agent's own mailbox, only for the recipients in RELAY_ALLOWED, and passes the message on untouched
but for its subject line, which subject.py sets from a marker the agent writes, within checks, and
an HTML version that htmlbody.py renders from the plain text as markdown.
Enforcing the allowlist here, below Hermes, is what makes it hold for replies, send_message,
scheduled jobs and anything a later release adds. Rationale: EMAIL.md.
"""
import asyncio
import hmac
import logging
import os
import smtplib
import ssl
import sys
import warnings

from aiosmtpd.smtp import SMTP, AuthResult, LoginPassword

import subject

# AUTH without TLS is deliberate: the relay's network has one other member, and the
# credential it carries is the one that member already holds. aiosmtpd says so on every
# connection, along with a notice about its own internals; quiet exactly those.
warnings.filterwarnings("ignore", message="Requiring AUTH while not requiring TLS")
_QUIET = ("auth_require_tls", "login_data is deprecated")
logging.getLogger("mail.log").addFilter(lambda rec: not any(q in rec.getMessage() for q in _QUIET))

ADDRESS = os.environ["RELAY_ADDRESS"]
PASSWORD = os.environ["RELAY_PASSWORD"]
ALLOWED = {a.strip().lower() for a in os.environ.get("RELAY_ALLOWED", "").split(",") if a.strip()}
UPSTREAM_HOST = os.environ["RELAY_UPSTREAM_HOST"]
UPSTREAM_PORT = int(os.environ.get("RELAY_UPSTREAM_PORT") or 587)
PORT = 2525


def log(msg):
    print(msg, flush=True)


def upstream():
    """A logged-in connection to the provider, certificate verified."""
    ctx = ssl.create_default_context()
    if UPSTREAM_PORT == 465:
        smtp = smtplib.SMTP_SSL(UPSTREAM_HOST, UPSTREAM_PORT, context=ctx, timeout=30)
    else:
        smtp = smtplib.SMTP(UPSTREAM_HOST, UPSTREAM_PORT, timeout=30)
        smtp.starttls(context=ctx)
    smtp.login(ADDRESS, PASSWORD)
    return smtp


def authenticate(server, session, envelope, mechanism, data):
    """The adapter always logs in; only the mailbox's own credentials are accepted."""
    ok = (isinstance(data, LoginPassword)
          and hmac.compare_digest(data.login, ADDRESS.encode())
          and hmac.compare_digest(data.password, PASSWORD.encode()))
    # handled=False: aiosmtpd then sends the 535 itself. The default, True, means the
    # authenticator already replied, and a refused login would get no answer at all.
    return AuthResult(success=ok, handled=False)


class Relay:
    async def handle_MAIL(self, server, session, envelope, address, mail_options):
        if address.lower() != ADDRESS.lower():
            log(f"refused sender {address}")
            return "553 5.7.1 Sender not permitted"
        envelope.mail_from = address
        envelope.mail_options.extend(mail_options)
        return "250 OK"

    async def handle_RCPT(self, server, session, envelope, address, rcpt_options):
        if address.lower() not in ALLOWED:
            log(f"refused recipient {address}")
            return "550 5.7.1 Recipient not permitted"
        envelope.rcpt_tos.append(address)
        return "250 OK"

    async def handle_DATA(self, server, session, envelope):
        content = envelope.original_content
        # A subject is a nicety: a message that will not parse still goes out as it came.
        try:
            content = subject.rewrite(content, log=log) or content
        except Exception as exc:
            log(f"subject left as sent: {type(exc).__name__}: {exc}")

        def forward():
            with upstream() as smtp:
                smtp.sendmail(envelope.mail_from, envelope.rcpt_tos, content)
        try:
            await asyncio.get_running_loop().run_in_executor(None, forward)
        except Exception as exc:
            log(f"upstream refused: {type(exc).__name__}: {exc}")
            return "451 4.4.1 Upstream delivery failed"
        log(f"relayed to {', '.join(envelope.rcpt_tos)}")
        return "250 OK"


async def main():
    if not ALLOWED:
        sys.exit("RELAY_ALLOWED is empty: nothing could ever be sent")
    try:
        upstream().quit()
    except Exception as exc:
        sys.exit(f"login to {UPSTREAM_HOST}:{UPSTREAM_PORT} failed: {type(exc).__name__}: {exc}")
    server = await asyncio.get_running_loop().create_server(
        lambda: SMTP(Relay(), hostname="mail", authenticator=authenticate,
                     auth_required=True, auth_require_tls=False),
        "0.0.0.0", PORT)
    log(f"relaying for {ADDRESS} to {len(ALLOWED)} recipient(s) via {UPSTREAM_HOST}:{UPSTREAM_PORT}")
    async with server:
        await server.serve_forever()


asyncio.run(main())
