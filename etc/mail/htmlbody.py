"""An HTML version of mail the agent sends, rendered from its plain text as markdown.

The adapter sends text/plain only, so markdown the agent writes arrives as literal
characters. The relay adds a text/html alternative built here to every message with a
body, and the plain text stays as the first part. The model never writes markup: the
parser runs with raw HTML off, so every tag it wrote is escaped, links are made only from
http(s) and mailto URLs, images become links rather than remote loads, and every link
whose text is not its own URL is followed by the host it actually goes to, so a title
cannot pass for a different destination. Rationale: EMAIL.md.

The digests' older plain-text conventions are read too, by translating them to markdown
first: a line in capitals is a section heading, and "- Title (origin): why" with a bare
URL indented beneath it becomes a linked title.
"""
import html
import os
import re
import time
import urllib.parse

from markdown_it import MarkdownIt

URL = re.compile(r"https?://[^\s<>\"'`]+")
TRAIL = ".,;:!?)]}'\""
HEADING = re.compile(r"^(?P<main>[A-Z][A-Z0-9 &/'+:,-]{1,60}?)(?:\s+\((?P<aside>[^()]{1,60})\))?:?$")
ITEM = re.compile(r"^(?P<lead>\s*[-•*]\s+)(?P<text>.*)$")
TITLED = re.compile(r"^(?P<title>.{2,160}?) \((?P<origin>[^()]{1,60})\)(?P<rest>(?::\s*.*)?)$")
LABELLED = re.compile(r"^(?P<title>[^:\[\]]{2,90})(?P<rest>:\s+.+)$")
CRON_HEADER = "Cronjob Response:"
RULE = re.compile(r"^-{3,}\s*$")
SAFE_SCHEMES = ("http", "https")
# A mailto link is a ready-made draft, so it is made only for an address the relay would
# deliver to anyway; any other stays text. The relay's own list, from its environment.
ALLOWED = {a.strip().lower() for a in os.environ.get("RELAY_ALLOWED", "").split(",") if a.strip()}

FONT = ("-apple-system,BlinkMacSystemFont,'Segoe UI',Inter,Roboto,'Helvetica Neue',"
        "Arial,sans-serif")
MONO = "ui-monospace,SFMono-Regular,Menlo,Consolas,monospace"
INK, BODY, MUTED, FAINT, LINE = "#0f172a", "#334155", "#64748b", "#94a3b8", "#e8ebf0"
ACCENT, TINT = "#4f46e5", "#f5f6fa"

# Email clients drop <style> unevenly, so every element carries its own.
STYLE = {
    "h1": f"margin:24px 0 6px;font-size:20px;line-height:1.3;color:{INK};font-weight:700;",
    "h2": (f"margin:28px 0 6px;font-size:12px;letter-spacing:.12em;text-transform:uppercase;"
           f"color:{ACCENT};font-weight:700;"),
    "h3": f"margin:20px 0 4px;font-size:15px;color:{INK};font-weight:700;",
    "h4": f"margin:16px 0 4px;font-size:14px;color:{INK};font-weight:700;",
    "h5": f"margin:16px 0 4px;font-size:14px;color:{INK};font-weight:600;",
    "h6": f"margin:16px 0 4px;font-size:13px;color:{MUTED};font-weight:600;",
    "p": "margin:12px 0 0;",
    "ul": "margin:10px 0 0;padding-left:22px;",
    "ol": "margin:10px 0 0;padding-left:22px;",
    "li": "margin:6px 0 0;",
    "a": f"color:{ACCENT};text-decoration:none;",
    "strong": f"color:{INK};font-weight:600;",
    "blockquote": f"margin:12px 0 0;padding:2px 0 2px 14px;border-left:3px solid {LINE};color:{MUTED};",
    "code": f"font-family:{MONO};font-size:13px;background:{TINT};padding:1px 4px;border-radius:4px;",
    "pre": (f"margin:12px 0 0;padding:12px 14px;background:{TINT};border-radius:8px;"
            f"font-family:{MONO};font-size:13px;line-height:1.45;white-space:pre-wrap;"),
    "hr": f"border:0;border-top:1px solid {LINE};margin:24px 0 0;",
    "table": "border-collapse:collapse;margin:12px 0 0;font-size:14px;",
    "th": f"text-align:left;padding:6px 10px;border-bottom:2px solid {LINE};color:{INK};",
    "td": f"padding:6px 10px;border-bottom:1px solid {LINE};vertical-align:top;",
}
HOST = f"color:{FAINT};font-size:12px;white-space:nowrap;"

# The inline styles are the frameless layout, which uses the full width of a phone. The
# frame (grey surround, bordered card, generous padding) is added only on a wide screen,
# and only by a client that honours <style> media queries; one that drops them falls back
# to frameless, never to a squashed card.
FRAME_CSS = f"""@media screen and (min-width:700px){{
.am-outer{{background:#f3f4f7 !important}}
.am-gutter{{padding:28px 12px !important}}
.am-card{{border:1px solid {LINE} !important;border-radius:16px !important}}
.am-head{{padding:30px 30px 6px !important}}
.am-body{{padding:4px 30px 30px !important}}
.am-foot{{padding:16px 12px 0 !important}}
}}"""


def esc(s):
    return html.escape(s, quote=True)


def host(u):
    if u.lower().startswith("mailto:"):
        return u[7:].split("?", 1)[0]
    h = (urllib.parse.urlsplit(u).hostname or "").lower()
    return h[4:] if h.startswith("www.") else h


def safe_link(url):
    """http(s) anywhere; mailto only to a listed address, with nothing prefilled."""
    scheme = url.split(":", 1)[0].strip().lower() if ":" in url else ""
    if scheme == "mailto":
        addr = urllib.parse.unquote(url[7:])
        return "?" not in addr and addr.strip().lower() in ALLOWED
    return scheme in SAFE_SCHEMES


def bare_url(s):
    s = s.strip()
    m = URL.fullmatch(s.rstrip(TRAIL)) if s else None
    return m.group(0) if m else None


def md_text(s):
    """Plain text made literal for markdown, for titles moved into link syntax."""
    return re.sub(r"([\\`*_\[\]<>!#])", r"\\\1", s)


def legacy(lines):
    """The digests' plain-text conventions, translated to the markdown they stand for."""
    out, i = [], 0
    while i < len(lines):
        raw = lines[i]
        s = raw.strip()
        prev_blank = not out or not out[-1].strip()
        m = ITEM.match(raw)
        if m and i + 1 < len(lines) and lines[i + 1][:1] in " \t" and bare_url(lines[i + 1]) \
                and not ITEM.match(lines[i + 1]):
            link, text = bare_url(lines[i + 1]), m.group("text")
            t = TITLED.match(text) or LABELLED.match(text)
            if t and "](" not in text:
                origin = f" ({t.group('origin')})" if "origin" in t.groupdict() else ""
                text = f"[{md_text(t.group('title'))}]({link}){origin}{t.group('rest')}"
            else:
                text = f"{text} {link}"
            out.append(m.group("lead") + text)
            i += 2
            continue
        if prev_blank and HEADING.match(s) and any(c.isalpha() for c in s) \
                and (i + 1 >= len(lines) or not lines[i + 1].strip() or not RULE.match(lines[i + 1])):
            out.extend([f"## {s.rstrip(':')}", ""])
        else:
            out.append(raw)
        i += 1
    return out


def strip_cron_header(lines):
    first = next((i for i, l in enumerate(lines) if l.strip()), None)
    if first is not None and lines[first].startswith(CRON_HEADER):
        rule = next((i for i in range(first + 1, min(first + 4, len(lines))) if RULE.match(lines[i])), None)
        if rule is not None:
            return lines[rule + 1:]
    return lines


def styled(tokens):
    for tok in tokens:
        if tok.nesting >= 0 and tok.tag in STYLE and tok.type != "inline":
            tok.attrSet("style", STYLE[tok.tag])
        if tok.children:
            styled(tok.children)


def parser():
    md = MarkdownIt("commonmark", {"html": False, "linkify": True, "typographer": False})
    md.enable(["table", "strikethrough", "linkify"])
    md.validateLink = safe_link
    md.linkify.set({"fuzzy_link": False, "fuzzy_email": False})
    rules = md.renderer.rules

    def link_close(tokens, idx, options, env):
        # The host follows any link whose visible text is not exactly the URL it goes to.
        # Bare URLs included: the parser shows an internationalised host decoded, so
        # https://аpple.com (Cyrillic а) reads as apple.com while the href is punycode.
        j = idx - 1
        while j >= 0 and tokens[j].type != "link_open":
            j -= 1
        href = tokens[j].attrGet("href") or ""
        shown = "".join(t.content for t in tokens[j + 1:idx] if t.type in ("text", "code_inline"))
        tail = "</a>"
        if shown.strip() not in (href, href.removeprefix("mailto:")):
            tail += f' <span style="{HOST}">&#8599;&nbsp;{esc(host(href))}</span>'
        return tail

    def image(tokens, idx, options, env):
        # No remote images: an image is a link to it, named by its alt text.
        tok = tokens[idx]
        src = tok.attrGet("src") or ""
        alt = esc(tok.content or "image")
        if not safe_link(src) or src.lower().startswith("mailto:"):
            return alt
        return (f'<a href="{esc(src)}" style="{STYLE["a"]}">{alt}</a> '
                f'<span style="{HOST}">&#8599;&nbsp;{esc(host(src))}</span>')

    rules["link_close"] = link_close
    rules["image"] = image
    return md


MD = parser()


def render(text, title=None):
    lines = legacy(strip_cron_header(text.splitlines()))
    tokens = MD.parse("\n".join(lines))
    styled(tokens)
    body = MD.renderer.render(tokens, MD.options, {})
    t = time.gmtime()
    date = f"{t.tm_mday} {time.strftime('%B %Y', t)}"
    heading = (f'<h1 style="margin:8px 0 0;font-size:24px;line-height:1.25;color:{INK};'
               f'font-weight:700;letter-spacing:-.01em;">{esc(title)}</h1>') if title else ""
    return f"""<!doctype html>
<html lang="en-GB"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light"><meta name="supported-color-schemes" content="light">
<title>{esc(title or "Hermes")}</title>
<style>{FRAME_CSS}</style></head>
<body style="margin:0;padding:0;background:#ffffff;">
<table role="presentation" class="am-outer" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#ffffff;">
<tr><td align="center" class="am-gutter" style="padding:0;">
<table role="presentation" class="am-card" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:640px;background:#ffffff;">
<tr><td class="am-head" style="padding:8px 2px 4px;font-family:{FONT};">
<div style="font-size:11.5px;letter-spacing:.14em;text-transform:uppercase;color:{FAINT};font-weight:600;">Amphora &middot; {esc(date)}</div>
{heading}
</td></tr>
<tr><td class="am-body" style="padding:0 2px 16px;font-family:{FONT};font-size:15px;line-height:1.55;color:{BODY};">
{body}
</td></tr></table>
<div class="am-foot" style="font-family:{FONT};font-size:12px;color:{FAINT};padding:8px 2px 0;">Sent by Hermes through Amphora</div>
</td></tr></table></body></html>
"""


def attach(part, text, title=None):
    """Turn the body's text/plain part into text/plain + text/html alternatives, in place.

    The part may be the whole message or the first part of the adapter's multipart/mixed."""
    if part.is_multipart() or part.get_content_type() != "text/plain" or not text.strip():
        return False
    part.add_alternative(render(text, title), subtype="html", charset="utf-8", cte="quoted-printable")
    return True
