"""Subject lines for mail the relay forwards.

The adapter picks the subject itself: "Re:" and the last inbound subject from that address,
or "Hermes Agent" when it has none. So the agent asks for one with a marker on the first
line of the body, `[[Subject: ...]]`, which is removed here and, if it passes the checks
below, becomes the subject. Those checks are structural, not injection detection: the text
is the model's, so an injected message can steer it, and what keeps that harmless is that
it reaches only the allowlist, carries a fixed tag, and cannot be shaped into a link, a
thread reply or a phishing lure. Anything with no marker keeps its subject. Every message
with a body also gains the HTML version htmlbody.py renders from it. Rationale: EMAIL.md.
"""
import email.policy
import re
import time
import unicodedata
from email.parser import BytesParser

import htmlbody

TAG = "[Amphora]"
DEFAULT_SUBJECTS = {"hermes agent", "re: hermes agent"}
MARKER = re.compile(r"^\s*\[\[Subject:(.*)\]\]\s*$", re.IGNORECASE)
CRON_HEADER = "Cronjob Response:"  # cron/scheduler_delivery.py, unless cron.wrap_response is off
RULE = re.compile(r"^-{3,}\s*$")
# Unicode categories dropped outright: controls (CR/LF included), format characters
# (bidi overrides, zero-width), private use, surrogates and unassigned.
DROP = {"Cc", "Cf", "Co", "Cs", "Cn"}
LINKISH = re.compile(r"@|://|\bwww\.|[a-z0-9-]+\.[a-z]{2,}\b", re.IGNORECASE)
THREADISH = re.compile(r"^(re|fwd?)\s*:", re.IGNORECASE)
# The shape of a lure, not of an injection: a hit costs a plain subject and nothing more.
LURE = re.compile(r"\b(urgent|password|verify|wire|payment|invoice|account|login|confirm|suspended)\b",
                  re.IGNORECASE)


def clean_text(text):
    """NFKC, without control, format, private-use or unassigned characters, one line."""
    text = unicodedata.normalize("NFKC", text)
    text = "".join(c for c in text if unicodedata.category(c) not in DROP)
    return " ".join(text.split())


def clean(text):
    """The subject a marker asks for, or (None, reason) if it fails a check."""
    text = clean_text(text)
    if not 3 <= len(text) <= 60:
        return None, f"length {len(text)}"
    for name, pattern in (("link", LINKISH), ("thread prefix", THREADISH), ("lure word", LURE)):
        if pattern.search(text):
            return None, name
    return text, None


def fallback():
    t = time.gmtime()
    return f"{TAG} {t.tm_mday} {time.strftime('%b %Y', t)}"


def body_part(msg):
    for part in msg.walk():
        if part.get_content_type() == "text/plain" and part.get_content_disposition() != "attachment":
            return part
    return None


def rewrite(raw, log=print):
    """The message with its subject set, or None if it should go out as it came in."""
    msg = BytesParser(policy=email.policy.default).parsebytes(raw)
    part = body_part(msg)
    subject, heading, text = None, None, None
    if part is not None:
        text = part.get_content()
        lines = text.splitlines(keepends=True)
        first = next((i for i, line in enumerate(lines) if line.strip()), None)
        # Scheduled output arrives under the gateway's "Cronjob Response:" header, which
        # ends in a line of dashes; the marker is the first line after it.
        if first is not None and lines[first].startswith(CRON_HEADER):
            rule = next((i for i in range(first + 1, min(first + 4, len(lines))) if RULE.match(lines[i])), None)
            if rule is not None:
                first = next((i for i in range(rule + 1, len(lines)) if lines[i].strip()), None)
        m = MARKER.match(lines[first]) if first is not None else None
        if m:
            before = "".join(lines[:first])
            text = (before if before.strip() else "") + "".join(lines[first + 1:]).lstrip("\r\n")
            part.set_content(text, charset="utf-8", cte="quoted-printable")
            cleaned, reason = clean(m.group(1))
            if cleaned:
                subject = f"{TAG} {cleaned}"
            else:
                log(f"subject marker refused ({reason}); using the fallback")
                subject = fallback()
            # The page heading is the marker's text even when the subject checks refused
            # it: in the body it is escaped text like the rest.
            heading = " ".join(clean_text(m.group(1)).split())[:120] or subject[len(TAG) + 1:]
    # Every body gets an HTML version rendered from its markdown, replies included. A
    # nicety like the subject: if it fails, the plain text goes out as it is.
    rendered = False
    if part is not None:
        try:
            rendered = htmlbody.attach(part, text, heading)
        except Exception as exc:
            log(f"html version skipped: {type(exc).__name__}: {exc}")
    if subject is None:
        if str(msg.get("Subject", "")).strip().lower() not in DEFAULT_SUBJECTS:
            return msg.as_bytes(policy=email.policy.SMTP) if rendered else None
        subject = fallback()
    del msg["Subject"]
    msg["Subject"] = subject
    return msg.as_bytes(policy=email.policy.SMTP)
