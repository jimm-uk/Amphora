# shellcheck shell=bash
# Signal: the signal-cli daemon, the adapter environment handed to Hermes, and `signal`.
# Sourced by bin/amphoractl, never run on its own.

# Signal. Optional: set AMPHORA_SIGNAL_ACCOUNT in etc/amphora.local to switch it on. With it
# empty, nothing below is created, started or passed to Hermes, and the stack behaves
# exactly as it did before Signal existed.
#
# Hermes' adapter talks HTTP to amphora-signal-relay (etc/signal/), which passes on only
# messages to the lists below. Behind it is the signal-cli daemon, whose interface has NO
# authentication of any kind, so its isolation is topological: it is on a network that only
# the relay shares. See SIGNAL.md before changing that.
C_SIGNAL="amphora-signal"
VOL_SIGNAL="amphora-signal-data"   # the account's identity keys — the one unrebuildable thing
NET_SIGNAL="amphora-signal-net"    # members: hermes, amphora-signal-relay. Nothing else, ever.
NET_SIGNALD="amphora-signald-net"  # members: amphora-signal, amphora-signal-relay. Never hermes.
C_SIGRELAY="amphora-signal-relay"
IMG_SIGRELAY="${AMPHORA_SIGNAL_RELAY_IMAGE:-amphora-signal-relay:local}"
SIGNAL_URL="http://signal-relay:8080"   # not the daemon's old name, so a rollback cannot clash
# Native (GraalVM) build: no JRE inside, so the Java version pinning that bites the
# JVM packaging cannot arise. Swap to ...signal-cli-jre:latest if the native build
# misbehaves during registration.
IMG_SIGNAL="${AMPHORA_SIGNAL_IMAGE:-registry.gitlab.com/packaging/signal-cli/signal-cli-native:latest}"

SIGNAL_ACCOUNT="${AMPHORA_SIGNAL_ACCOUNT:-}"  # E.164 number signal-cli owns
SIGNAL_ALLOWED="${AMPHORA_SIGNAL_ALLOWED:-}"  # who may talk to the agent — number AND ACI UUID
SIGNAL_HOME="${AMPHORA_SIGNAL_HOME:-}"        # where cron jobs and proactive messages land
SIGNAL_GROUPS="${AMPHORA_SIGNAL_GROUPS:-}"    # group IDs the agent answers in — one session each

signal_enabled() { [ -n "$SIGNAL_ACCOUNT" ]; }

# An account ID, or a number with its country code: all the relay can match.
signal_id_ok() {
  printf '%s\n' "$1" | grep -Eqi '^(\+[1-9][0-9]{6,14}|[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12})$'
}

# Both lists are handed to the adapter, as whom it listens to, and to the relay, as whom it
# may write to. In Hermes the group list only filters which groups arrive: each sender in
# one is still matched against SIGNAL_ALLOWED_USERS. "*" would open either, so it is
# refused; whitespace is refused because signal_args() is word-split into podman arguments.
signal_check() {
  signal_enabled || return 0
  local bad=0 id list old_ifs="$IFS"
  case "$SIGNAL_GROUPS" in
    *[[:space:]]*) c_red "  signal: whitespace in AMPHORA_SIGNAL_GROUPS"; bad=1 ;;
    *'*'*) c_red "  signal: '*' in AMPHORA_SIGNAL_GROUPS — list group IDs (amphoractl signal groups)"; bad=1 ;;
  esac
  case "$SIGNAL_ALLOWED" in
    '') c_red "  signal: AMPHORA_SIGNAL_ALLOWED is empty — nothing could be received or sent"; return 1 ;;
    *[[:space:]]*) c_red "  signal: whitespace in AMPHORA_SIGNAL_ALLOWED"; return 1 ;;
    *'*'*) c_red "  signal: '*' in AMPHORA_SIGNAL_ALLOWED — list numbers or account IDs"; return 1 ;;
  esac
  IFS=','
  for id in $SIGNAL_ALLOWED; do
    signal_id_ok "$id" || { c_red "  signal: an entry in AMPHORA_SIGNAL_ALLOWED is neither +<number> nor an account ID"; bad=1; }
  done
  IFS="$old_ifs"
  if [ -n "$SIGNAL_HOME" ]; then
    case "$SIGNAL_HOME" in
      group:*) list=",$SIGNAL_GROUPS,"; id="${SIGNAL_HOME#group:}" ;;
      *)       list=",$SIGNAL_ALLOWED,"; id="$SIGNAL_HOME" ;;
    esac
    case "$list" in
      *",$id,"*) ;;
      *) c_red "  signal: AMPHORA_SIGNAL_HOME is not on the list — the relay would refuse it"; bad=1 ;;
    esac
  fi
  return $bad
}

signal_require() {
  signal_enabled || die "no Signal account configured — set AMPHORA_SIGNAL_ACCOUNT in etc/amphora.local (see etc/amphora.local.example)"
}

# The image runs as its own unprivileged signal-cli user, but a fresh podman volume is
# root-owned. Hand it over once; harmless to repeat.
signal_ensure_volume() {
  podman volume exists "$VOL_SIGNAL" 2>/dev/null || podman volume create "$VOL_SIGNAL" >/dev/null
  podman run --rm --entrypoint chown \
    -v "$VOL_SIGNAL:/var/lib/signal-cli" \
    "$IMG_SIGNAL" -R signal-cli:signal-cli /var/lib/signal-cli >/dev/null 2>&1 || true
}

# One-shot signal-cli against the same volume the daemon uses. signal-cli takes an
# exclusive lock on the account, so the daemon is stopped for the call and put back
# afterwards if it was up.
signal_cli() {
  local was_running=1 rc=0
  if running "$C_SIGNAL"; then
    was_running=0
    podman stop -t 5 "$C_SIGNAL" >/dev/null 2>&1 || true
  fi
  podman run --rm \
    -v "$VOL_SIGNAL:/var/lib/signal-cli" \
    --tmpfs /tmp:exec \
    "$IMG_SIGNAL" "$@" || rc=$?
  if [ $was_running -eq 0 ]; then podman start "$C_SIGNAL" >/dev/null 2>&1 || true; fi
  return $rc
}

signal_logs() {
  podman container exists "$C_SIGNAL" 2>/dev/null \
    || die "no $C_SIGNAL container yet — 'amphoractl up' creates it once the account is registered"
  podman logs -f "$C_SIGNAL"
}

# True once register + verify have completed. Asks signal-cli rather than inspecting the
# volume: its on-disk layout is not a stable interface, and a wrong guess about it fails
# closed — the daemon never starts and doctor reports an account that plainly works.
#
# A running daemon is itself proof of registration, and returning early on that also keeps
# this off the account lock: signal-cli takes an exclusive lock, so the listAccounts call
# below is only ever made when nothing else holds it.
signal_registered() {
  signal_enabled || return 1
  running "$C_SIGNAL" && return 0
  podman volume exists "$VOL_SIGNAL" 2>/dev/null || return 1
  # Captured rather than piped: `grep -q` exits on the first match, and the SIGPIPE that
  # gives podman would fail the pipeline under `set -o pipefail`.
  local out
  out="$(podman run --rm \
    -v "$VOL_SIGNAL:/var/lib/signal-cli" \
    --tmpfs /tmp:exec \
    "$IMG_SIGNAL" listAccounts 2>/dev/null || true)"
  printf '%s' "$out" | grep -q -- "$SIGNAL_ACCOUNT"
}

# isolate=strict stops other networks reaching this one by IP address; podman's default does
# so today, but nothing else here asks for it. doctor probes it rather than trusting either.
signal_networks() {
  podman network exists "$NET_SIGNAL" 2>/dev/null || podman network create "$NET_SIGNAL" >/dev/null
  podman network exists "$NET_SIGNALD" 2>/dev/null \
    || podman network create --opt isolate=strict "$NET_SIGNALD" >/dev/null
}

build_signal_relay() {
  local log="${TMPDIR:-/tmp}/amphoractl-signal-build.$$.log"
  [ -f "$STACK_DIR/etc/signal/Containerfile" ] || die "etc/signal/Containerfile missing"
  if ! podman build -t "$IMG_SIGRELAY" "$STACK_DIR/etc/signal" > "$log" 2>&1; then
    tail -40 "$log" >&2
    rm -f "$log"
    die "Signal relay image build failed"
  fi
  rm -f "$log"
  c_grn "  $IMG_SIGRELAY built"
}

# The sending allowlist. Its lists are fixed at create, so it is recreated whenever Hermes
# is. The outbox is here only so a link in it can be recognised and refused.
start_signal_relay() {
  podman image exists "$IMG_SIGRELAY" || build_signal_relay
  signal_networks
  podman rm -f "$C_SIGRELAY" >/dev/null 2>&1 || true
  podman run -d \
    --name "$C_SIGRELAY" \
    --label "$OWNER_LABEL=$STACK_DIR" \
    --network "$NET_SIGNAL:alias=signal-relay" --network "$NET_SIGNALD" \
    --restart unless-stopped \
    --read-only --cap-drop all --security-opt no-new-privileges \
    --memory 128m \
    -v "$OUTBOX_HOST:$SB_OUTBOX:ro" \
    -e RELAY_ACCOUNT="$SIGNAL_ACCOUNT" \
    -e RELAY_ALLOWED="$SIGNAL_ALLOWED" \
    -e RELAY_GROUPS="$SIGNAL_GROUPS" \
    -e RELAY_OUTBOX="$SB_OUTBOX" \
    "$IMG_SIGRELAY" >/dev/null
}

# Not published, and on a network of its own with the relay: sandbox traffic is masqueraded
# out through amphora-dind onto amphora-net, so anything living there is reachable by IP
# from the agent. The daemon is unauthenticated, so the only thing keeping anyone from the
# bot's Signal identity is the absence of a route to it.
start_signal() {
  bind_source_check "$OUTBOX_HOST" "the outbox (AMPHORA_OUTBOX)" || return 1
  signal_networks
  podman rm -f "$C_SIGNAL" >/dev/null 2>&1 || true
  podman run -d \
    --name "$C_SIGNAL" \
    --label "$OWNER_LABEL=$STACK_DIR" \
    --network "$NET_SIGNALD" --network-alias signal-cli \
    --restart unless-stopped \
    --memory 512m \
    -v "$VOL_SIGNAL:/var/lib/signal-cli" \
    -v "$OUTBOX_HOST:$SB_OUTBOX:ro" \
    --tmpfs /tmp:exec \
    "$IMG_SIGNAL" -a "$SIGNAL_ACCOUNT" daemon --http 0.0.0.0:8080 >/dev/null
  start_signal_relay
  # Probe through the relay, from a throwaway container: hermes may not exist yet.
  local i
  for i in $(seq 1 30); do
    if podman run --rm --network "$NET_SIGNAL" --entrypoint sh "$IMG_DIND" \
         -c "wget -q -O /dev/null $SIGNAL_URL/api/v1/check" >/dev/null 2>&1; then
      c_grn "  signal-cli daemon answering through the relay"
      return 0
    fi
    sleep 2
  done
  c_ylw "  signal-cli not answering through the relay yet — amphoractl logs signal-relay"
  return 0
}

# For config push: the relay alone, unless the daemon predates it.
refresh_signal() {
  signal_enabled && signal_registered || return 0
  if podman inspect "$C_SIGNAL" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null \
       | grep -qw -- "$NET_SIGNALD"; then
    start_signal_relay
  else
    start_signal
  fi
}

remove_signal() {
  podman rm -f "$C_SIGRELAY" >/dev/null 2>&1 || true
  podman rm -f "$C_SIGNAL" >/dev/null 2>&1 || true
}

# The relay as doctor sees it. Nothing here can send: the recipient in the test is a number
# no one can have, and the other call only reads.
signal_relay_probe() {
  podman exec -e SIG_URL="$SIGNAL_URL" -e SIG_ACCOUNT="$SIGNAL_ACCOUNT" -e SIG_OK="${SIGNAL_ALLOWED%%,*}" \
    "$C_HERMES" python3 -c '
import json, os, urllib.error, urllib.parse, urllib.request as u
url, acct = os.environ["SIG_URL"], os.environ["SIG_ACCOUNT"]
def rpc(method, params):
    req = u.Request(url + "/api/v1/rpc", headers={"Content-Type": "application/json"}, data=json.dumps(
        {"jsonrpc": "2.0", "id": "doctor", "method": method, "params": dict(params, account=acct)}).encode())
    return (json.load(u.urlopen(req, timeout=15)).get("error") or {}).get("code")
try:
    ok = u.urlopen(url + "/relay/allows?recipient=" + urllib.parse.quote(os.environ["SIG_OK"], safe=""), timeout=15).status == 200
except urllib.error.HTTPError:
    ok = False
print("listed-refused" if not ok else
      "stranger-allowed" if rpc("send", {"recipient": ["+10000000000"], "message": "doctor"}) != -32001 else
      "call-allowed" if rpc("listDevices", {}) != -32001 else "ok")
' 2>/dev/null </dev/null | tr -d '\r' || true
}

# The groups the bot is a member of, one "id<TAB>name<TAB>members" line each. Asked of
# the running daemon over JSON-RPC from the hermes container, the adapter's own route,
# so unlike signal_cli it pauses nothing.
signal_group_list() {
  podman exec -e SIG_URL="$SIGNAL_URL" -e SIG_ACCOUNT="$SIGNAL_ACCOUNT" "$C_HERMES" python3 -c '
import json, os, urllib.request as u
req = u.Request(os.environ["SIG_URL"] + "/api/v1/rpc", headers={"Content-Type": "application/json"},
    data=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "listGroups",
                     "params": {"account": os.environ["SIG_ACCOUNT"]}}).encode())
res = json.load(u.urlopen(req, timeout=10))
if "error" in res:
    raise SystemExit(str(res["error"]))
for g in res.get("result") or []:
    if not g.get("isMember") or g.get("isBlocked"):
        continue
    # Any member can rename a group, so the name is untrusted text bound for a
    # terminal: whitespace collapsed, and nothing unprintable (escapes included) kept.
    name = " ".join(str(g.get("name") or "").split())
    name = "".join(ch for ch in name if ch.isprintable()) or "(unnamed)"
    print("%s\t%s\t%d" % (g["id"], name, len(g.get("members") or [])))
'
}

# AMPHORA_SIGNAL_GROUPS as the groups' names, for status output. A group ID is an
# identifier best kept out of terminals, logs and screenshots, and the name tells a
# person the same thing. A listed group the bot has left shows the first characters of
# its ID, enough to find the entry in etc/amphora.local. Without the daemon to ask, a
# count.
signal_group_names() {
  local list="" asked=0 g name out="" n=0 old_ifs="$IFS"
  [ -n "$SIGNAL_GROUPS" ] || return 0
  if running "$C_HERMES" && running "$C_SIGNAL" && list="$(signal_group_list 2>/dev/null)"; then
    asked=1
  fi
  IFS=','
  for g in $SIGNAL_GROUPS; do
    n=$((n + 1))
    [ "$asked" -eq 1 ] || continue
    name="$(printf '%s\n' "$list" | awk -F'\t' -v id="$g" '$1 == id { print $2; exit }')"
    [ -n "$name" ] || name="a group the bot has left (id ${g:0:6}…)"
    out="${out:+$out, }$name"
  done
  IFS="$old_ifs"
  if [ "$asked" -eq 1 ]; then
    printf '%s\n' "$out"
  else
    printf '%d listed (names need hermes and %s running)\n' "$n" "$C_SIGNAL"
  fi
}

# Sets AMPHORA_SIGNAL_GROUPS in etc/amphora.local: replaces the line if there is one,
# appends it if not. Anything less plain than a bare assignment is left for a human.
signal_groups_write() {
  local f="$STACK_DIR/etc/amphora.local" val="$1"
  [ -f "$f" ] || die "no $f"
  if grep -Eq '^[[:space:]]*export[[:space:]]+AMPHORA_SIGNAL_GROUPS=|^[[:space:]]+AMPHORA_SIGNAL_GROUPS=' "$f"; then
    die "AMPHORA_SIGNAL_GROUPS in $f is not a plain assignment — set it by hand to: $val"
  fi
  if grep -q '^AMPHORA_SIGNAL_GROUPS=' "$f"; then
    local tmp="$f.tmp.$$"
    awk -v line="AMPHORA_SIGNAL_GROUPS=\"$val\"" \
      '/^AMPHORA_SIGNAL_GROUPS=/ { print line; next } { print }' "$f" > "$tmp" \
      && cat "$tmp" > "$f"
    rm -f "$tmp"
  else
    printf '\n# Signal groups the agent answers in, one session each (amphoractl signal groups)\nAMPHORA_SIGNAL_GROUPS="%s"\n' "$val" >> "$f"
  fi
}

# Emits the Signal adapter's network and environment, or nothing at all when there is no
# registered account. Same newline-separated word-splitting as secret_args(); safe only
# because none of these values contains whitespace.
signal_args() {
  signal_enabled || return 0
  signal_registered || return 0
  printf -- '--network\n%s\n' "$NET_SIGNAL"
  printf -- '-e\nSIGNAL_HTTP_URL=%s\n' "$SIGNAL_URL"
  printf -- '-e\nSIGNAL_ACCOUNT=%s\n' "$SIGNAL_ACCOUNT"
  [ -n "$SIGNAL_ALLOWED" ] && printf -- '-e\nSIGNAL_ALLOWED_USERS=%s\n' "$SIGNAL_ALLOWED"
  [ -n "$SIGNAL_HOME" ] && printf -- '-e\nSIGNAL_HOME_CHANNEL=%s\n' "$SIGNAL_HOME"
  [ -n "$SIGNAL_GROUPS" ] && printf -- '-e\nSIGNAL_GROUP_ALLOWED_USERS=%s\n' "$SIGNAL_GROUPS"
  return 0
}

# ------------------------------------------------------------------ signal --
# ${1+"$@"} throughout: bash 3.2 errors on a bare "$@" under `set -u` when there are no
# positional parameters, and every one of these takes optional trailing flags.
cmd_signal() {
  need_podman
  local sub="${1:-status}"
  shift || true
  case "$sub" in

    register)
      signal_require
      signal_ensure_volume
      local captcha="${1:-}"
      shift || true
      [ -n "$captcha" ] || die "usage: amphoractl signal register '<signalcaptcha://...>' [--reregister] [--voice]"
      info "registering $SIGNAL_ACCOUNT — captcha tokens are short-lived, so this is one shot"
      signal_cli -a "$SIGNAL_ACCOUNT" register --captcha "$captcha" ${1+"$@"} || {
        c_red "registration failed"
        info "'already registered' — this number still holds a Signal account from before."
        info "  Re-run with --reregister to take it over, or wipe it first:"
        info "  amphoractl signal reset server"
        info "'captcha' — the token expired. Get a fresh one and re-run immediately:"
        info "  https://signalcaptchas.org/registration/generate.html"
        return 1
      }
      c_grn "verification code sent to $SIGNAL_ACCOUNT"
      info "next: amphoractl signal verify <code> [--pin <PIN>]" ;;

    verify)
      signal_require
      local code="${1:-}"
      shift || true
      [ -n "$code" ] || die "usage: amphoractl signal verify <code> [--pin <PIN>]"
      signal_cli -a "$SIGNAL_ACCOUNT" verify "$code" ${1+"$@"} || {
        c_red "verification failed"
        info "'Registration lock' — the number's old Signal PIN is still set on the account."
        info "  Pass it: amphoractl signal verify <code> --pin <PIN>"
        info "  Lost it? The lock lapses after 7 days of account inactivity."
        return 1
      }
      c_grn "registered"
      info "next: amphoractl signal pin set <PIN>, then amphoractl up" ;;

    pin)
      signal_require
      case "${1:-}" in
        set)
          [ -n "${2:-}" ] || die "usage: amphoractl signal pin set <PIN>"
          signal_cli -a "$SIGNAL_ACCOUNT" setPin "$2"
          c_grn "registration lock set — keep this PIN, re-registering the number needs it" ;;
        remove)
          signal_cli -a "$SIGNAL_ACCOUNT" removePin
          c_ylw "registration lock removed — anyone who gets the SIM can take the account" ;;
        *) die "usage: amphoractl signal pin [set <PIN>|remove]" ;;
      esac ;;

    name)
      signal_require
      [ -n "${1:-}" ] || die "usage: amphoractl signal name <display name>"
      signal_cli -a "$SIGNAL_ACCOUNT" updateProfile --given-name "$1"
      c_grn "profile name set — this is what you will see in your contact list" ;;

    send)
      signal_require
      local msg="${1:-}" to="${2:-$SIGNAL_HOME}"
      [ -n "$msg" ] || die "usage: amphoractl signal send <message> [recipient]"
      [ -n "$to" ] || die "no recipient — set AMPHORA_SIGNAL_HOME in etc/amphora.local, or pass one"
      signal_cli -a "$SIGNAL_ACCOUNT" send -m "$msg" "$to"
      c_grn "sent"
      info "this path bypasses Hermes entirely — it proves the daemon, not the agent" ;;

    status)
      signal_require
      info "account   $SIGNAL_ACCOUNT"
      info "allowlist ${SIGNAL_ALLOWED:-<empty>}"
      info "home      ${SIGNAL_HOME:-<unset>}"
      if [ -n "$SIGNAL_GROUPS" ]; then
        info "groups    $(signal_group_names)"
      else
        info "groups    <none — groups ignored>"
      fi
      if signal_registered; then c_grn "  registered"; else c_red "  not registered"; fi
      if running "$C_SIGNAL"; then c_grn "  daemon running"; else c_ylw "  daemon not running"; fi ;;

    # Offers each group the bot is in for AMPHORA_SIGNAL_GROUPS, writes the answer into
    # etc/amphora.local and offers the config push. Writes that file, so the dispatch
    # line owner_checks it.
    groups)
      signal_require
      { running "$C_HERMES" && running "$C_SIGNAL"; } \
        || die "needs $C_HERMES and $C_SIGNAL running — amphoractl up"
      local list id name n a cur="$SIGNAL_GROUPS" added=0
      list="$(signal_group_list)" || die "could not list groups from the signal-cli daemon"
      if [ -z "$list" ]; then
        info "the bot is in no groups — create one in the Signal app with the bot's number in it"
        return 0
      fi
      while IFS=$'\t' read -r id name n; do
        case ",$cur," in *",$id,"*) c_grn "  $name — already answered in"; continue ;; esac
        # etc/amphora.local is sourced, so nothing but a base64 group ID goes into it.
        case "$id" in ''|*[!A-Za-z0-9+/=]*) c_ylw "  $name — unexpected group id, skipped"; continue ;; esac
        if [ "$n" -gt 2 ]; then
          info "$name has $n members — only senders on AMPHORA_SIGNAL_ALLOWED get answers"
        fi
        read -r -p "Add '$name' ($n members)? [y/N] " a </dev/tty
        [ "$a" = "y" ] || continue
        cur="${cur:+$cur,}$id"
        added=1
      done <<EOF
$list
EOF
      # Listed groups the bot has left or been removed from: harmless, but worth knowing.
      local old_ifs="$IFS" g
      IFS=','
      for g in $SIGNAL_GROUPS; do
        case "$list" in *"$g"*) ;; *) c_ylw "  listed but the bot is not in it: id ${g:0:6}…" ;; esac
      done
      IFS="$old_ifs"
      [ "$added" -eq 1 ] || return 0
      SIGNAL_GROUPS="$cur"
      signal_check || die "refusing to write that list"
      signal_groups_write "$cur"
      c_grn "AMPHORA_SIGNAL_GROUPS updated in etc/amphora.local"
      read -r -p "Apply now? This runs config push, which recreates hermes. [y/N] " a
      if [ "$a" = "y" ]; then cmd_config_push; else info "later: amphoractl config push"; fi ;;

    logs) signal_logs ;;

    # The app-free clean slate. Signal Desktop cannot register a primary account and the
    # handset route needs the Signal app, so this is the only way to start from an empty
    # account when there is no phone to install it on.
    reset)
      signal_require
      case "${1:-}" in
        local)
          read -r -p "Delete local signal-cli state for $SIGNAL_ACCOUNT? The account stays registered at Signal. [y/N] " a
          [ "$a" = "y" ] || { echo "aborted"; return 0; }
          podman rm -f "$C_SIGNAL" >/dev/null 2>&1 || true
          signal_cli -a "$SIGNAL_ACCOUNT" deleteLocalAccountData --ignore-registered || true
          c_grn "local state gone"
          info "the number is still registered at Signal — re-register with --reregister" ;;
        server)
          c_ylw "This deletes the Signal account for $SIGNAL_ACCOUNT from Signal's servers."
          info "It is the clean slate that does not need the Signal app on a handset."
          info "Anyone who has messaged this number loses the conversation. Cannot be undone."
          read -r -p "Type the number to confirm: " a
          [ "$a" = "$SIGNAL_ACCOUNT" ] || { echo "aborted"; return 0; }
          podman rm -f "$C_SIGNAL" >/dev/null 2>&1 || true
          signal_cli -a "$SIGNAL_ACCOUNT" unregister --delete-account \
            || c_ylw "  server-side delete failed — the local wipe still runs"
          signal_cli -a "$SIGNAL_ACCOUNT" deleteLocalAccountData --ignore-registered || true
          c_grn "account deleted — register from scratch, no --reregister needed" ;;
        *) die "usage: amphoractl signal reset [local|server]" ;;
      esac ;;

    *) die "usage: amphoractl signal [register|verify|pin|name|send|groups|status|logs|reset]" ;;
  esac
}
