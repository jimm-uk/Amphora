#!/usr/bin/env python3
"""amphora-feeds: fetch a fixed list of feeds, clean the text, and hand new items to the agent.

FEEDS.md is the design and the threat model; this file is the mechanism. Everything here
runs outside the agent's reach: the source list is baked into the image, and seen ids,
held items and counts live in a volume the agent cannot mount. The only thing that
crosses is what this writes into the inbox, and held text never does.

Modes:
  (none)            loop: fetch every FEEDS_INTERVAL seconds
  --once            one fetch now
  --check URL [type [pattern]]   fetch one URL, report what it parses to; no state
  --held [N]        the last N held items (default 20), for a human
  --replay [N] [NAME]  forget the first N ids (default 1) each source lists, normally
                    its newest, or NAME's alone, so the next run reports them again
  --stats           per-source table, for a human
  --status-age      seconds since the last completed run, or -1
  --validate        check feeds.csv and exit
"""
import csv
import fcntl
import html.parser
import json
import os
import re
import signal
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

import feedparser
import defusedxml.ElementTree as DET
from defusedxml import DefusedXmlException

FEEDS_FILE = os.environ.get("FEEDS_FILE", "/app/feeds.csv")
STATE = os.environ.get("FEEDS_STATE", "/state")
INBOX = os.environ.get("FEEDS_INBOX", "/inbox")
INTERVAL = int(os.environ.get("FEEDS_INTERVAL", "10800"))

MAX_BYTES = 5 * 1024 * 1024
TIMEOUT = 20
UA = "amphora-feeds/1 (personal feed reader)"
CAP = {"release": 1500, "zeitgeist": 25000}   # characters of item text, after cleaning
SEEN_KEEP = 500                                # ids remembered per source beyond the current feed
MAX_LINKS = 300                                # links kept per zeitgeist item
MAX_NEW = 25                                   # new items per source per run; the rest marked seen
HELD_KEEP = 200                                # held records kept for `feeds held`
WINDOW = 28 * 86400                            # the scorecard's window
TYPES = ("rss", "atom", "hf", "page")
TIERS = ("release", "zeitgeist")
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,39}")


def log(msg):
    print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg, flush=True)


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)) if t else None


# ------------------------------------------------------------------ the list --

def load_feeds(path=FEEDS_FILE):
    """One source per line, comma-separated: name,type,tier,url[,pattern].

    Each line is parsed as a CSV record of its own, so a field that holds a comma goes in
    double quotes and none can span lines. Spaces around a field are dropped, and a line
    starting with # is a comment, which is not CSV and is why the file is read by line.
    """
    feeds, names = [], set()
    with open(path, encoding="utf-8-sig", newline="") as fh:
        for n, line in enumerate(fh, 1):
            line = line.rstrip("\r\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            try:
                f = [x.strip() for x in next(csv.reader([line], skipinitialspace=True, strict=True))]
            except csv.Error as e:
                raise ValueError(f"feeds.csv line {n}: {e}")
            if len(f) not in (4, 5):
                hint = " (this line has tabs; the list is comma-separated)" if "\t" in line else ""
                raise ValueError(f"feeds.csv line {n}: want name,type,tier,url[,pattern]; "
                                 f"quote a field that contains a comma{hint}")
            name, typ, tier, url = f[:4]
            pattern = f[4] if len(f) == 5 else ""
            if not NAME_RE.fullmatch(name):
                raise ValueError(f"feeds.csv line {n}: name must be 1-40 of letters, digits, space . _ -")
            if name in names:
                raise ValueError(f"feeds.csv line {n}: duplicate name {name!r}")
            if typ not in TYPES:
                raise ValueError(f"feeds.csv line {n}: type must be one of {', '.join(TYPES)}")
            if tier not in TIERS:
                raise ValueError(f"feeds.csv line {n}: tier must be one of {', '.join(TIERS)}")
            if urllib.parse.urlsplit(url).scheme != "https":
                raise ValueError(f"feeds.csv line {n}: https only")
            rx = None
            if typ == "page":
                if not pattern:
                    raise ValueError(f"feeds.csv line {n}: a page source needs a link pattern")
                rx = re.compile(pattern)
            names.add(name)
            feeds.append({"name": name, "type": typ, "tier": tier, "url": url, "rx": rx})
    return feeds


# --------------------------------------------------------- guard 1: fetching --

class SameHostRedirect(urllib.request.HTTPRedirectHandler):
    """A source may move within its own host, never to another one."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        old = urllib.parse.urlsplit(req.full_url)
        new = urllib.parse.urlsplit(urllib.parse.urljoin(req.full_url, newurl))
        if new.scheme != "https" or new.hostname != old.hostname:
            raise urllib.error.HTTPError(req.full_url, code,
                                         f"redirect off-host refused ({new.hostname})", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}), SameHostRedirect)


def fetch(url):
    if urllib.parse.urlsplit(url).scheme != "https":
        raise ValueError("https only")
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with OPENER.open(req, timeout=TIMEOUT) as resp:
        data = resp.read(MAX_BYTES + 1)
        charset = resp.headers.get_content_charset()
    if len(data) > MAX_BYTES:
        raise ValueError("response over 5 MB")
    return data, charset


# ------------------------------------------------------- guard 2: cleaning --

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "param", "source", "track", "wbr"}
SKIP = {"script", "style", "template", "noscript", "head", "iframe", "object", "svg", "math"}
BLOCK = {"p", "div", "br", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "tr",
         "pre", "blockquote", "section", "article", "table", "hr", "dd", "dt"}
HIDDEN_STYLE = re.compile(
    r"display\s*:\s*none|visibility\s*:\s*hidden"
    r"|font-size\s*:\s*0(\.0+)?(px|em|rem|pt|%)?\s*(;|$|!)"
    r"|opacity\s*:\s*0(\.0+)?\s*(;|$|!)", re.I)


# A link's place in the text, as [L3]. While the text is being cleaned it is held in two
# private-use characters, which a feed cannot supply: handle_data drops them. After that
# it is [L3], and a feed's own "[L3]" has become "(L3)", so it cannot borrow a link.
MARK_OPEN, MARK_CLOSE = "\ue000", "\ue001"
MARK = re.compile(r" \[L\d{1,3}\]")


def link_url(u):
    """A link the agent may offer: https, a plain public host name, no login, nothing that
    reads like an instruction. None for anything else."""
    try:   # a malformed href raises, and must not end the parse
        u = good_url(u)
        if not u or not u.isascii():
            return None
        p = urllib.parse.urlsplit(u)
        host, port = p.hostname or "", p.port
    except ValueError:
        return None
    if p.scheme != "https" or port not in (None, 443) or "@" in p.netloc or "\\" in u:
        return None
    if not re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*[a-z0-9]", host):
        return None
    if host.startswith("xn--") or ".xn--" in host:
        return None
    if re.search(r"[<>\"'`\[\]{}()|^]", u):
        return None
    spaced = re.sub(r"[-_+/=&?.]+", " ", urllib.parse.unquote(u))
    if hits(urllib.parse.unquote(u)) or hits(spaced):
        return None
    return u


def mark_links(s):
    """Cleaned text with sentinels -> text with [Ln] markers."""
    s = re.sub(r"\[(\s*[Ll]\s*\d+\s*)\]", r"(\1)", s)
    return re.sub(f"\\s*{MARK_OPEN}(L\\d+){MARK_CLOSE}", r" [\1]", s)


class _Text(html.parser.HTMLParser):
    """HTML to text. Content a reader would not see — scripts, styles, and elements hidden
    by attribute or inline style — is dropped, since hidden text is where an instruction
    aimed at a model rather than a person would sit. An unclosed hidden element swallows
    the rest of the document, which fails in the safe direction."""

    def __init__(self, links=None):
        super().__init__(convert_charrefs=True)
        self.out, self.skip, self.hidden = [], [], 0
        # With a dict, visible links are numbered into it and marked where they close.
        self.links, self.href = links, None

    def _mark(self):
        """Close the open link: a marker after its text, if it had any."""
        if self.href is None:
            return
        u, at = self.href
        self.href = None
        if not "".join(self.out[at:]).strip():
            return
        lid = next((k for k, v in self.links.items() if v == u), None)
        if lid is None:
            if len(self.links) >= MAX_LINKS:
                return
            lid = f"L{len(self.links) + 1}"
            self.links[lid] = u
        self.out.append(f"{MARK_OPEN}{lid}{MARK_CLOSE}")

    def handle_starttag(self, tag, attrs):
        if self.skip:
            if tag == self.skip[-1] and tag not in VOID:
                self.skip.append(tag)
            return
        a = {k: (v or "") for k, v in attrs}
        hide = (tag in SKIP or "hidden" in a or a.get("aria-hidden", "").lower() == "true"
                or HIDDEN_STYLE.search(a.get("style", "")))
        if hide and tag not in VOID:
            self.skip.append(tag)
            if tag not in SKIP:
                self.hidden += 1
            return
        if tag in BLOCK:
            self._mark()
            self.out.append("\n")
        if tag == "a" and self.links is not None:
            self._mark()
            u = link_url(a.get("href"))
            if u:
                self.href = (u, len(self.out))

    def handle_endtag(self, tag):
        if self.skip:
            if tag == self.skip[-1]:
                self.skip.pop()
            return
        if tag == "a" or tag in BLOCK:
            self._mark()
        if tag in BLOCK:
            self.out.append("\n")

    def handle_data(self, d):
        if not self.skip:
            self.out.append(d.replace(MARK_OPEN, "").replace(MARK_CLOSE, ""))


def html_to_text(s, links=None):
    p = _Text(links)
    try:
        p.feed(s or "")
        p.close()
    except Exception:  # a parser that gives up has still collected what it saw
        pass
    return "".join(p.out), p.hidden


EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")


def clean(s, keep=""):
    """NFKC, then drop every control, format (zero-width, bidi, the U+E0000 tag block),
    private-use, surrogate and unassigned character, as the relay's subject check does.
    Addresses are removed rather than held: they turn up in co-author lines constantly,
    and nothing the agent sends can reach one anyway."""
    s = unicodedata.normalize("NFKC", s or "")
    s = s.replace(" ", "\n").replace(" ", "\n").replace("\r", "\n")
    s = "".join(ch for ch in s
                if ch in "\n\t" or ch in keep or unicodedata.category(ch) not in ("Cc", "Cf", "Co", "Cs", "Cn"))
    s = EMAIL_RE.sub("[address removed]", s)
    s = re.sub(r"[ \t ]+", " ", s)
    s = "\n".join(line.strip() for line in s.split("\n"))
    return re.sub(r"\n{3,}", "\n\n", s).strip()


def one_line(s, cap):
    s = clean(s).replace("\n", " ")
    return s if len(s) <= cap else s[: cap - 1] + "…"


# --------------------------------------------------- guard 3: quarantining --

_F = re.I | re.M
RULES = [
    ("instruction override", re.compile(
        r"\b(ignore|disregard|forget|override)\b[^.\n]{0,40}\b(previous|prior|above|earlier|"
        r"preceding|all|any|your)\b[^.\n]{0,30}\b(instructions?|prompts?|rules|directions|"
        r"guidelines|context)\b", _F)),
    ("new instructions", re.compile(r"\b(new|updated|real|actual|hidden)\s+instructions?\s*:", _F)),
    ("addressed to a model", re.compile(
        r"\b(if you are|you are|as) an? (ai|llm|language model|assistant|agent|chatbot)\b[^.\n]{0,60}"
        r"\b(reading|summari[sz]ing|processing|must|should)\b"
        r"|\bnote to (the )?(ai|llm|agent|assistant|model|summari[sz]er)\b"
        r"|\b(ai|llm|agent|assistant|model)s?\s+(reading|summari[sz]ing|processing) this\b", _F)),
    ("role switch", re.compile(
        r"\byou are now (a|an|the|my|in|acting|operating)\b|\bfrom now on,? you (are|will|must)\b"
        r"|\bact as (if you|an? |the )(ai|assistant|agent|system|developer|admin)", _F)),
    ("chat markup", re.compile(
        r"<\|im_(start|end)\|>|\[/?INST\]|<\|(system|user|assistant)\|>|</?(system|assistant)>"
        r"|^\s*#{0,3}\s*(system|assistant)\s*:", _F)),
    ("delivery or tool token", re.compile(
        r"MEDIA:\s*/|/mounts/|/opt/data\b|\bdeliver\s*=|\bcronjob_manage\b|\bsend_message\b", _F)),
    ("shell payload", re.compile(
        r"\b(curl|wget)\b[^\n]{0,200}\|\s*(sudo\s+)?(ba|z|da)?sh\b|\bbase64\s+(-d|--decode)\b"
        r"|\brm\s+-rf\s+[/~]", _F)),
    ("encoded blob", re.compile(r"[A-Za-z0-9+/]{200,}={0,2}")),
]


def hits(s):
    return [name for name, rx in RULES if rx.search(s)]


def screen(item, tier):
    """Return (item or None, held records). A title that trips a rule holds the whole
    item; in the body only the tripping paragraphs are withheld, so a long AINews issue
    that quotes a jailbreak loses that paragraph rather than the day. If more than half
    the body goes, the item is held whole."""
    held = []
    r = hits(item["title"])
    if r:
        return None, [{"reason": ", ".join(r), "text": item["title"] + "\n\n" + item["text"]}]
    # Judged without link markers: one inside a phrase would hide it from the rules.
    paras = re.split(r"\n\s*\n", item["text"]) if item["text"] else []
    kept, lost = [], 0
    for p in paras:
        r = hits(MARK.sub("", p))
        if r:
            held.append({"reason": ", ".join(r), "text": p})
            kept.append(f"[paragraph withheld by the feed filter: {', '.join(r)}]")
            lost += len(p)
        else:
            kept.append(p)
    total = sum(len(p) for p in paras)
    if total and lost * 2 > total:
        return None, [{"reason": "most of the item withheld: " + "; ".join(h["reason"] for h in held),
                       "text": item["title"] + "\n\n" + item["text"]}]
    text = "\n\n".join(kept)
    cap = CAP[tier]
    if len(text) > cap:
        text = text[: cap - 1].rstrip() + "…"
    out = dict(item, text=text)
    if "links" in item:
        # Only links whose marker is still there: not past the cap, not in a withheld paragraph.
        out["links"] = {k: u for k, u in item["links"].items() if f" [{k}]" in text}
    return out, held


# ---------------------------------------------------------------- extraction --

def good_url(u):
    u = (u or "").strip()
    p = urllib.parse.urlsplit(u)
    if p.scheme in ("http", "https") and p.hostname and len(u) <= 500 and not re.search(r"\s", u):
        return u
    return None


def struct_iso(st):
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", st) if st else None
    except Exception:
        return None


def parse_feed(data, with_links=False):
    # defusedxml is only the gate: it refuses DTD entity tricks outright. A document it
    # merely cannot parse goes on to feedparser, whose loose parser expands no entities.
    try:
        DET.fromstring(data)
    except DefusedXmlException as e:
        raise ValueError(f"XML refused ({type(e).__name__})")
    except ET.ParseError:
        pass
    d = feedparser.parse(data)
    if not d.entries and d.get("bozo"):
        raise ValueError("feed did not parse")
    items = []
    for e in d.entries:
        url = good_url(e.get("link"))
        if not url:
            continue
        body = ""
        if e.get("content"):
            body = e.content[0].get("value", "")
        elif e.get("summary"):
            body = e.summary
        title, _ = html_to_text(e.get("title", ""))
        links = {} if with_links else None
        text, _ = html_to_text(body, links)
        text = mark_links(clean(text, MARK_OPEN + MARK_CLOSE)) if with_links else clean(text)
        ident = str(e.get("id") or url)[:500]
        items.append({"id": ident, "url": url, "title": one_line(title, 200),
                      "published": struct_iso(e.get("published_parsed") or e.get("updated_parsed")),
                      "text": text})
        if links:
            items[-1]["links"] = links
    return items


HF_ID = re.compile(r"[A-Za-z0-9][\w.-]{0,95}/[A-Za-z0-9][\w.-]{0,95}")
HF_TIME = re.compile(r"\d{4}-\d\d-\d\dT[\d:.]+Z")


def parse_hf(data):
    rows = json.loads(data)
    if not isinstance(rows, list):
        raise ValueError("expected a JSON list")
    items = []
    for m in rows:
        if not isinstance(m, dict) or not isinstance(m.get("id"), str) or not HF_ID.fullmatch(m["id"]):
            continue
        tags = [str(t) for t in (m.get("tags") or [])[:30] if isinstance(t, (str, int))]
        created = m.get("createdAt") if isinstance(m.get("createdAt"), str) else ""
        text = "Pipeline: " + str(m.get("pipeline_tag") or "unknown") + "\nTags: " + ", ".join(tags)
        items.append({"id": m["id"], "url": "https://huggingface.co/" + m["id"],
                      "title": m["id"], "published": created if HF_TIME.fullmatch(created) else None,
                      "text": clean(text)})
    return items


ANCHOR = re.compile(r"<a\b[^>]*?\bhref\s*=\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>", re.I | re.S)


def parse_page(data, charset, page_url, rx):
    """Link titles only. The model never fetches, so an article body is never read."""
    doc = data.decode(charset or "utf-8", "replace")
    host = urllib.parse.urlsplit(page_url).hostname
    found = {}
    for href, inner in ANCHOR.findall(doc):
        u = good_url(urllib.parse.urljoin(page_url, href.strip()))
        if not u:
            continue
        p = urllib.parse.urlsplit(u)
        if p.hostname != host or not rx.fullmatch(p.path):
            continue
        u = urllib.parse.urlunsplit((p.scheme, p.netloc, p.path, "", ""))
        title, _ = html_to_text(inner)
        title = one_line(title, 200)
        if len(title) > len(found.get(u, "")):
            found[u] = title
        found.setdefault(u, "")
    return [{"id": u, "url": u, "title": t or u, "published": None, "text": ""}
            for u, t in found.items()]


def extract(feed, data, charset):
    if feed["type"] == "hf":
        return parse_hf(data)
    if feed["type"] == "page":
        return parse_page(data, charset, feed["url"], feed["rx"])
    return parse_feed(data, feed["tier"] == "zeitgeist")


# --------------------------------------------------------------------- state --

def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, ValueError):
        return default


def write_atomic(path, obj):
    """Temp file then rename. O_NOFOLLOW|O_EXCL on the temp file, and rename replaces a
    symlink at the destination rather than following it, so nothing the agent plants in
    the inbox can redirect a write."""
    d = os.path.dirname(path)
    tmp = os.path.join(d, f".tmp-{os.getpid()}-{time.time_ns()}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def read_used():
    """URLs the agent says it used. Agent-written, so advisory: read with a size cap,
    without following links, and only ever counted."""
    d = os.path.join(INBOX, "used")
    used, cutoff = set(), time.time() - WINDOW
    try:
        names = os.listdir(d)
    except OSError:
        return used
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            fd = os.open(os.path.join(d, n), os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as fh:
                if os.fstat(fh.fileno()).st_mtime < cutoff:
                    continue
                obj = json.loads(fh.read(65536))
            for u in obj.get("used", []) if isinstance(obj, dict) else []:
                if isinstance(u, str) and len(u) <= 500:
                    used.add(u)
        except (OSError, ValueError):
            continue
    return used


def safe_error(e):
    msg = one_line(f"{type(e).__name__}: {e}", 140)
    return "fetch failed (detail withheld by the feed filter)" if hits(msg) else msg


def status_doc(feeds, stats, seeded):
    used, now = read_used(), time.time()
    rows = []
    for f in feeds:
        st = stats["sources"].get(f["name"], {})
        rep = [u for t, u in st.get("reported", []) if t >= now - WINDOW]
        rows.append({
            "name": f["name"], "tier": f["tier"], "ok": "error" not in st,
            "last_ok": iso(st.get("last_ok")), "failing_since": iso(st.get("failing_since")),
            "error": st.get("error"), "reported_28d": len(rep),
            "used_28d": sum(1 for u in rep if u in used),
            "held_28d": sum(1 for t in st.get("held", []) if t >= now - WINDOW),
        })
    return {"format": 1, "updated_at": iso(now), "interval_s": INTERVAL,
            "seeded": seeded, "sources": rows}


# ----------------------------------------------------------------------- run --

def run_once(feeds):
    os.makedirs(STATE, exist_ok=True)
    lock = open(os.path.join(STATE, "lock"), "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        seen = load_json(os.path.join(STATE, "seen.json"), {})
        stats = load_json(os.path.join(STATE, "stats.json"), {"sources": {}})
        stats.setdefault("sources", {})
        now = time.time()
        items_out, held_out, held_log, seeded, new_seen = [], [], [], [], {}
        for f in feeds:
            st = stats["sources"].setdefault(f["name"], {})
            st["last_try"] = now
            try:
                data, charset = fetch(f["url"])
                items = extract(f, data, charset)
            except Exception as e:
                st["error"] = safe_error(e)
                st.setdefault("failing_since", now)
                log(f"{f['name']}: {st['error']}")
                continue
            st.pop("error", None)
            st.pop("failing_since", None)
            st["last_ok"] = now
            ids = list(dict.fromkeys(i["id"] for i in items))
            known = seen.get(f["name"])
            if known is None:
                # A new source, or state lost: everything already there counts as seen.
                # One quiet run, never a backlog.
                new_seen[f["name"]] = ids
                seeded.append(f["name"])
                log(f"{f['name']}: seeded with {len(ids)} items")
                continue
            kset = set(known)
            fresh = [i for i in items if i["id"] not in kset]
            # A feed that renumbers its ids, or is replaced wholesale, would otherwise
            # arrive as a flood. The newest few go through; the rest are marked seen.
            skipped = max(0, len(fresh) - MAX_NEW)
            fresh = fresh[:MAX_NEW]
            reported = [p for p in st.get("reported", []) if p[0] >= now - WINDOW]
            heldt = [t for t in st.get("held", []) if t >= now - WINDOW]
            for it in fresh:
                out, held = screen(it, f["tier"])
                for h in held:
                    held_log.append({"at": iso(now), "source": f["name"], "url": it["url"],
                                     "title": it["title"], "reason": h["reason"],
                                     "text": h["text"][:2000]})
                if out is None:
                    held_out.append({"source": f["name"], "url": it["url"],
                                     "reason": held[0]["reason"] if held else "held"})
                    heldt.append(now)
                    continue
                if held:
                    heldt.append(now)
                items_out.append(dict(out, source=f["name"], tier=f["tier"]))
                reported.append([now, it["url"]])
            st["reported"], st["held"] = reported, heldt
            # Everything the feed lists now, then older ids it has dropped, so an item
            # that falls out and comes back is still known. Never truncated below the
            # feed's own length, which is what a fixed cap did to OpenAI's 1,300 items.
            cur = set(ids)
            older = [i for i in known if i not in cur][:SEEN_KEEP]
            new_seen[f["name"]] = ids + older
            log(f"{f['name']}: {len(items)} in feed, {len(fresh)} new"
                + (f", {skipped} more marked seen unreported" if skipped else ""))
            if skipped:
                st["skipped_last"] = skipped

        if not os.path.isdir(INBOX) or os.path.islink(INBOX):
            raise RuntimeError(f"{INBOX} is not a directory — nothing written, nothing marked seen")
        if items_out or held_out:
            # A manual `feeds run` can land in the same second as the loop's own run, and
            # rename would silently replace the earlier batch. The fixed-width sequence
            # keeps names sorting in the order they were written.
            base, n = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now)), 1
            stamp = f"{base}-01"
            while os.path.lexists(os.path.join(INBOX, f"{stamp}.json")):
                n += 1
                stamp = f"{base}-{n:02d}"
            write_atomic(os.path.join(INBOX, f"{stamp}.json"),
                         {"format": 1, "fetched_at": iso(now), "items": items_out, "held": held_out})
            log(f"batch {stamp}: {len(items_out)} items, {len(held_out)} held")
        # Only once the batch is safely down does anything count as seen.
        seen.update(new_seen)
        for name in list(seen):
            if name not in {f["name"] for f in feeds}:
                del seen[name]
        stats["last_run"] = now
        write_atomic(os.path.join(STATE, "seen.json"), seen)
        write_atomic(os.path.join(STATE, "stats.json"), stats)
        if held_log:
            prev = load_json(os.path.join(STATE, "held.json"), [])
            write_atomic(os.path.join(STATE, "held.json"), (prev + held_log)[-HELD_KEEP:])
        write_atomic(os.path.join(INBOX, "status.json"), status_doc(feeds, stats, seeded))
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


# -------------------------------------------------------- the human commands --

def cmd_check(argv):
    url = argv[0]
    typ = argv[1] if len(argv) > 1 else ""
    pattern = argv[2] if len(argv) > 2 else ""
    data, charset = fetch(url)
    if not typ:
        try:
            rows = json.loads(data)
            typ = "hf" if isinstance(rows, list) else "rss"
        except ValueError:
            typ = "rss"
    feed = {"name": "check", "type": typ, "tier": "release", "url": url,
            "rx": re.compile(pattern) if pattern else None}
    if typ == "page" and not pattern:
        raise SystemExit("a page source needs a link pattern, e.g. '/news/[a-z0-9-]+'")
    items = extract(feed, data, charset)
    held = sum(1 for i in items if screen(i, "release")[1])
    print(f"type     {typ}")
    print(f"items    {len(items)}")
    print(f"held     {held} would trip the filter")
    for i in items[:8]:
        print(f"  {one_line(i['title'], 90)}")
        print(f"    {i['url']}")


def cmd_held(argv):
    n = int(argv[0]) if argv else 20
    for h in load_json(os.path.join(STATE, "held.json"), [])[-n:]:
        print(f"{h['at']}  {h['source']}  — {h['reason']}")
        print(f"  {h['url']}")
        for line in clean(h["text"])[:600].split("\n"):
            print(f"    {line}")
        print()


def cmd_replay(feeds, argv):
    """--replay [N] [NAME]: forget the first N ids of NAME, or of every source."""
    try:
        n = int(argv[0]) if argv else 1
    except ValueError:
        n = 0
    if not 1 <= n <= MAX_NEW:
        raise SystemExit(f"replay: n must be 1-{MAX_NEW}")
    names = [f["name"] for f in feeds]
    if len(argv) > 1:
        if argv[1] not in names:
            raise SystemExit("replay: no such source; names are as in feeds.csv: "
                             + ", ".join(names))
        names = [argv[1]]
    os.makedirs(STATE, exist_ok=True)
    lock = open(os.path.join(STATE, "lock"), "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        path = os.path.join(STATE, "seen.json")
        seen = load_json(path, {})
        for name in names:
            if name not in seen:
                # Never fetched: the next run seeds it, and replaying would not change that.
                print(f"{name}: not fetched yet, skipped")
                continue
            # seen[name] starts with the ids in the order the feed listed them last run.
            seen[name] = seen[name][n:]
            print(f"{name}: newest {n} will be reported again")
        write_atomic(path, seen)
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def cmd_stats(feeds):
    doc = status_doc(feeds, load_json(os.path.join(STATE, "stats.json"), {"sources": {}}), [])
    print(f"{'source':<24} {'tier':<9} {'state':<8} {'last ok':<21} 28d: rep used held")
    for r in doc["sources"]:
        state = "ok" if r["ok"] else "FAILING"
        print(f"{r['name']:<24} {r['tier']:<9} {state:<8} {(r['last_ok'] or 'never'):<21}"
              f"      {r['reported_28d']:>3} {r['used_28d']:>4} {r['held_28d']:>4}")
        if not r["ok"]:
            print(f"  since {r['failing_since']}: {r['error']}")


def main(argv):
    if argv[:1] == ["--validate"]:
        print(f"{len(load_feeds())} sources")
        return
    if argv[:1] == ["--check"] and len(argv) >= 2:
        cmd_check(argv[1:])
        return
    if argv[:1] == ["--held"]:
        cmd_held(argv[1:])
        return
    if argv[:1] == ["--status-age"]:
        t = load_json(os.path.join(STATE, "stats.json"), {}).get("last_run")
        print(int(time.time() - t) if t else -1)
        return
    feeds = load_feeds()
    if argv[:1] == ["--stats"]:
        cmd_stats(feeds)
        return
    if argv[:1] == ["--replay"]:
        cmd_replay(feeds, argv[1:])
        return
    if argv[:1] == ["--once"]:
        run_once(feeds)
        return
    if argv:
        raise SystemExit(__doc__)
    # PID 1 ignores SIGTERM unless it installs a handler, and podman stop would then
    # wait out its timeout.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    log(f"{len(feeds)} sources, every {INTERVAL}s")
    while True:
        try:
            run_once(feeds)
        except Exception as e:
            log(f"run failed: {type(e).__name__}: {e}")
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main(sys.argv[1:])
