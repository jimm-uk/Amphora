"""Relay between Hermes and the signal-cli daemon.

Hermes sends through this, never straight to the daemon, which is on a network Hermes has no
interface on. A message leaves only for a person or group on the lists, and only the calls
Hermes' adapter makes are passed on: each is checked parameter by parameter and rebuilt, never
forwarded as it came. Incoming messages pass through untouched. Rationale: SIGNAL.md.
"""
import http.client
import http.server
import json
import os
import re
import stat
import sys
import threading
import time
import urllib.parse

ACCOUNT = os.environ.get("RELAY_ACCOUNT", "")
BACKEND = os.environ.get("RELAY_BACKEND", "signal-cli:8080")
OUTBOX = os.environ.get("RELAY_OUTBOX", "/mounts/outbox")
PORT = int(os.environ.get("RELAY_PORT", "8080"))

MAX_BODY = 1024 * 1024
RPC_TIMEOUT = 600        # a large attachment takes signal-cli minutes
EVENT_TIMEOUT = 300      # longer than the daemon's keep-alive, so silence means it has gone
REFUSED = -32001
NUMBER = re.compile(r"\+[1-9][0-9]{6,14}")
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
GROUP = re.compile(r"[A-Za-z0-9+/]{20,}={0,2}")


def split(name):
    return {v.strip() for v in os.environ.get(name, "").split(",") if v.strip()}


PEOPLE = {p.lower() for p in split("RELAY_ALLOWED")}
GROUPS = split("RELAY_GROUPS")


class Refused(Exception):
    pass


def log(msg):
    print(msg, flush=True)


def mask(v):
    """Enough of an identifier to recognise, and no more."""
    v = "".join(c for c in str(v) if c.isalnum() or c in "+-")
    return v[:3] + "…" + v[-2:] if len(v) > 8 else "…"


# ----------------------------------------------------------------- the daemon --

def backend(timeout):
    return http.client.HTTPConnection(BACKEND, timeout=timeout)


def ask(method, params):
    """A question of the relay's own."""
    conn = backend(30)
    try:
        conn.request("POST", "/api/v1/rpc", json.dumps(
            {"jsonrpc": "2.0", "id": "relay", "method": method, "params": params}),
            {"Content-Type": "application/json"})
        resp = conn.getresponse()
        if resp.status != 200:
            return None
        return json.loads(resp.read(32 * 1024 * 1024)).get("result")
    except (OSError, ValueError, AttributeError, http.client.HTTPException):
        return None
    finally:
        conn.close()


_known, _asked, _lock = {}, 0.0, threading.Lock()


def number_of(uuid):
    """The number signal-cli knows an account ID by, or None. Hermes swaps a listed number
    for its ID before sending, so a list of numbers has to be read this way round."""
    global _known, _asked
    with _lock:
        now = time.monotonic()
        # A hit is kept an hour; a miss may ask again after 15 seconds.
        if not _asked or now - _asked > (3600 if uuid in _known else 15):
            _asked = now
            found = {}
            contacts = ask("listContacts", {"account": ACCOUNT, "allRecipients": True})
            for c in contacts if isinstance(contacts, list) else ():
                if not isinstance(c, dict):
                    continue
                p = c.get("profile") if isinstance(c.get("profile"), dict) else {}
                n = c.get("number")
                for u in (c.get("uuid"), c.get("serviceId"), p.get("serviceId"), p.get("uuid")):
                    if isinstance(u, str) and isinstance(n, str) and NUMBER.fullmatch(n):
                        found[u.lower()] = n
            if isinstance(contacts, list):
                _known = found
        return _known.get(uuid)


# ------------------------------------------------------------------- the rules --

def person(v):
    if not isinstance(v, str):
        raise Refused("recipient is not text")
    if NUMBER.fullmatch(v):
        if v in PEOPLE:
            return v
    elif UUID.fullmatch(v.lower()):
        if v.lower() in PEOPLE or number_of(v.lower()) in PEOPLE:
            return v.lower()
    raise Refused(f"recipient {mask(v)} is not on the list")


def people(v):
    if isinstance(v, str):
        v = [v]
    if not isinstance(v, list) or not v:
        raise Refused("no recipient")
    return [person(x) for x in v]


def group(v):
    if not isinstance(v, str) or v not in GROUPS:
        raise Refused(f"group {mask(v)} is not on the list")
    return v


def account(v):
    if v != ACCOUNT:
        raise Refused("not this account")
    return v


def text(v):
    if not isinstance(v, str):
        raise Refused("text expected")
    return v


def texts(v):
    if not isinstance(v, list):
        raise Refused("list expected")
    return [text(x) for x in v]


def flag(v):
    if not isinstance(v, bool):
        raise Refused("true or false expected")
    return v


def stamp(v):
    if isinstance(v, bool) or not isinstance(v, int):
        raise Refused("number expected")
    return v


def author(v):
    """Whose message a reaction is to. It names, and is sent to, nobody."""
    if isinstance(v, str) and (NUMBER.fullmatch(v) or UUID.fullmatch(v.lower())):
        return v
    raise Refused("bad author")


def attachment_id(v):
    if not isinstance(v, str) or not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}", v):
        raise Refused("bad attachment id")
    return v


def outbox_files(v):
    """Files in the outbox only. The agent writes that folder, so a link in it could name
    the account keys beside the daemon: the path is resolved, and must not have moved."""
    root = os.path.realpath(OUTBOX)
    for p in texts(v):
        if not p.startswith(OUTBOX + "/") or os.path.normpath(p) != p or "\0" in p:
            raise Refused("attachment outside the outbox")
        try:
            ok = (os.path.realpath(p) == root + p[len(OUTBOX):]
                  and stat.S_ISREG(os.lstat(p).st_mode))
        except (OSError, ValueError):
            ok = False
        if not ok:
            raise Refused("attachment is missing, or not a plain file in the outbox")
    return v


TARGET = {"recipient": people, "groupId": group}
CALLS = {
    "send": dict(TARGET, account=account, message=text, attachments=outbox_files,
                 textStyle=text, textStyles=texts),
    "sendTyping": dict(TARGET, account=account, stop=flag),
    "sendReaction": dict(TARGET, account=account, emoji=text, targetAuthor=author,
                         targetTimestamp=stamp, remove=flag),
    "listContacts": {"account": account, "allRecipients": flag},
    "listGroups": {"account": account},
    "getContact": {"account": account, "contactAddress": author},
    "getAttachment": {"account": account, "id": attachment_id},
}
TARGETED = {"send", "sendTyping", "sendReaction"}


def no_repeats(pairs):
    d = dict(pairs)
    if len(d) != len(pairs):
        raise Refused("repeated key")
    return d


def rebuild(body):
    """(id, request to pass on). Raises Refused, with .rid set where the id is known."""
    def number(_):
        raise Refused("not a number")
    try:
        req = json.loads(body, object_pairs_hook=no_repeats, parse_constant=number)
    except Refused:
        raise
    except (ValueError, RecursionError):
        raise Refused("not JSON")
    if not isinstance(req, dict):
        raise Refused("one request at a time")
    rid = req.get("id")
    if isinstance(rid, bool) or not isinstance(rid, (str, int)):
        rid = None
    try:
        if rid is None or set(req) != {"jsonrpc", "method", "params", "id"} or req["jsonrpc"] != "2.0":
            raise Refused("malformed request")
        method, params = req["method"], req["params"]
        if not isinstance(method, str) or method not in CALLS:
            raise Refused(f"call {mask(method)} is not allowed")
        if not isinstance(params, dict) or "account" not in params:
            raise Refused("no account")
        rules, out = CALLS[method], {}
        for k, v in params.items():
            if k not in rules:
                raise Refused(f"{method}: parameter not allowed")
            out[k] = rules[k](v)
        if method in TARGETED and len(set(out) & set(TARGET)) != 1:
            raise Refused(f"{method}: exactly one of recipient and groupId")
    except Refused as e:
        e.rid = rid
        raise
    return rid, {"jsonrpc": "2.0", "id": rid, "method": method, "params": out}


# ------------------------------------------------------------------ the server --

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    timeout = 60
    server_version, sys_version = "relay", ""

    def log_message(self, *a):
        pass

    def reply(self, code, obj=None):
        data = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.close_connection = True

    def relay_response(self, conn):
        """Copy the daemon's answer as it arrives; the body ends when the connection does."""
        resp = conn.getresponse()
        self.send_response(resp.status)
        self.send_header("Content-Type", resp.getheader("Content-Type") or "application/json")
        if resp.getheader("Content-Length"):
            self.send_header("Content-Length", resp.getheader("Content-Length"))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        while True:
            chunk = resp.read1(65536)
            if not chunk:
                break
            self.wfile.write(chunk)
            self.wfile.flush()

    def forward(self, method, path, body=None, timeout=RPC_TIMEOUT):
        conn = backend(timeout)
        started = False
        try:
            conn.request(method, path, body, {"Content-Type": "application/json"} if body else {})
            started = True
            self.relay_response(conn)
        except (OSError, http.client.HTTPException) as e:
            self.close_connection = True
            if not started:
                log(f"daemon unreachable: {type(e).__name__}")
                self.reply(502)
        finally:
            conn.close()

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        if self.path == "/api/v1/check":
            return self.forward("GET", "/api/v1/check", timeout=10)
        if url.path == "/api/v1/events":
            q = urllib.parse.parse_qsl(url.query, keep_blank_values=True)
            if q == [("account", ACCOUNT)]:
                return self.forward("GET", "/api/v1/events?account="
                                    + urllib.parse.quote(ACCOUNT, safe=""), timeout=EVENT_TIMEOUT)
        if url.path == "/relay/allows":     # for doctor: the rule, with nothing sent
            q = urllib.parse.parse_qsl(url.query)
            try:
                if len(q) != 1 or q[0][0] != "recipient":
                    raise Refused("bad query")
                person(q[0][1])
                return self.reply(200, {"allowed": True})
            except Refused:
                return self.reply(403, {"allowed": False})
        log("refused path")
        self.reply(403)

    def do_POST(self):
        length = self.headers.get("Content-Length") or ""
        if (self.path != "/api/v1/rpc" or "Transfer-Encoding" in self.headers
                or not re.fullmatch(r"[0-9]{1,8}", length) or int(length) > MAX_BODY):
            log("refused path or size")
            return self.reply(403)
        try:
            rid, req = rebuild(self.rfile.read(int(length)))
        except Refused as e:
            log(f"refused: {e}")
            return self.reply(200, {"jsonrpc": "2.0", "id": getattr(e, "rid", None), "error": {
                "code": REFUSED, "message": f"refused by the Signal relay: {e}"}})
        self.forward("POST", "/api/v1/rpc", json.dumps(req).encode())


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        log(f"connection ended: {sys.exc_info()[0].__name__}")


def main():
    if not NUMBER.fullmatch(ACCOUNT):
        sys.exit("RELAY_ACCOUNT is not a phone number")
    if not PEOPLE:
        sys.exit("RELAY_ALLOWED is empty: nothing could ever be sent")
    for p in PEOPLE:
        if not (NUMBER.fullmatch(p) or UUID.fullmatch(p)):
            sys.exit(f"RELAY_ALLOWED: {mask(p)} is neither a number nor an account ID")
    for g in GROUPS:
        if not GROUP.fullmatch(g):
            sys.exit("RELAY_GROUPS: not a group ID")
    log(f"relaying to {len(PEOPLE)} people and {len(GROUPS)} groups")
    Server(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
