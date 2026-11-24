# shellcheck shell=bash
# Feeds: the AI-watch fetcher (amphora-feeds), its source list and its commands.
# Sourced by bin/amphoractl, never run on its own. FEEDS.md has the design.

# Optional: on when etc/feeds.csv exists and has an active line. With it absent there is
# no container, image, network or volume, and the stack is identical to one without it.
#
# The container fetches a fixed list, cleans and screens what it gets, and writes batches
# into the agent's inbox. The list and the filter are baked into its image from this
# checkout, and its seen ids and held items live in a volume nothing else mounts, so the
# agent can neither add a source nor weaken the filter, nor replay or hide an item. The
# inbox is the only crossing.
FEEDS_FILE="${AMPHORA_FEEDS_FILE:-$STACK_DIR/etc/feeds.csv}"
FEEDS_FILE_OLD="$STACK_DIR/etc/feeds.tsv"   # the tab-separated list, until 2026-11-16
FEEDS_INBOX="${AMPHORA_FEEDS_INBOX:-$WORKSPACE_HOST/ai-watch/inbox}"  # -> /projects/ai-watch/inbox
FEEDS_INTERVAL="${AMPHORA_FEEDS_INTERVAL:-10800}"                      # seconds between fetches
C_FEEDS="amphora-feeds"
NET_FEEDS="amphora-feeds-net"      # amphora-feeds alone. Never dind, never amphora-net.
VOL_FEEDS="amphora-feeds-state"    # seen ids, held items, counts. Rebuilds itself: not backed up.
IMG_FEEDS="${AMPHORA_FEEDS_IMAGE:-amphora-feeds:local}"
FEEDS_LIST_LABEL="io.amphora.feeds-list"

feeds_enabled() {
  [ -f "$FEEDS_FILE" ] && grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$FEEDS_FILE" >/dev/null 2>&1
}

# A checkout that still has only the tab-separated list would read as "feeds off", and
# `up` would remove the fetcher without a word. That state is refused instead.
feeds_list_stale() { [ -f "$FEEDS_FILE_OLD" ] && [ ! -f "$FEEDS_FILE" ]; }

feeds_list_check() {
  feeds_list_stale || return 0
  die "etc/feeds.tsv is the old tab-separated list and $FEEDS_FILE does not exist.
  Rewrite it as etc/feeds.csv: commas for the tabs, and double quotes round any field
  that contains a comma (etc/feeds.csv.example). Then remove etc/feeds.tsv."
}

# Change detection only: the image is labelled with the checksum of the list it was built
# from, so doctor can say when etc/feeds.csv has moved on since the last push.
feeds_list_sum() { cksum < "$FEEDS_FILE" | awk '{print $1}'; }

# A symlink anywhere between the projects folder and the inbox would let the agent
# point the bind somewhere else at the next create. Echoes the offending path; 0 = found.
feeds_inbox_link() {
  local p="$FEEDS_INBOX"
  while [ -n "$p" ] && [ "$p" != "/" ]; do
    if [ -L "$p" ]; then echo "$p"; return 0; fi
    [ "$p" = "$WORKSPACE_HOST" ] && break
    p="${p%/*}"
  done
  return 1
}

feeds_interval_ok() {
  case "$FEEDS_INTERVAL" in ''|*[!0-9]*) return 1 ;; esac
  [ "$FEEDS_INTERVAL" -ge 900 ]
}

# Like the mail relay, the context is streamed to the machine, so etc/ need not be a
# share. It is assembled in a temporary folder because the list lives in etc/, beside
# per-machine files that have no business in a build context.
build_feeds() {
  local ctx log
  [ -f "$STACK_DIR/etc/feeds/Containerfile" ] || die "etc/feeds/Containerfile missing"
  feeds_enabled || die "no active source in $FEEDS_FILE — start from etc/feeds.csv.example"
  ctx="$(mktemp -d "${TMPDIR:-/tmp}/amphoractl-feeds.XXXXXX")"
  log="$ctx.log"
  cp "$STACK_DIR/etc/feeds/Containerfile" "$STACK_DIR/etc/feeds/fetch.py" "$ctx/"
  cp "$FEEDS_FILE" "$ctx/feeds.csv"
  if ! podman build -t "$IMG_FEEDS" \
         --build-arg HOST_UID="$HOST_UID" --build-arg HOST_GID="$HOST_GID" \
         --label "$FEEDS_LIST_LABEL=$(feeds_list_sum)" \
         "$ctx" > "$log" 2>&1; then
    tail -20 "$log" >&2
    rm -rf "$ctx" "$log"
    die "feeds image build failed — a list that does not parse fails here"
  fi
  rm -rf "$ctx" "$log"
  c_grn "  $IMG_FEEDS built ($(grep -c -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$FEEDS_FILE") sources)"
}

# Removed outright when the list is gone, so switching feeds off leaves nothing running.
start_feeds() {
  local link
  feeds_list_check
  podman rm -f "$C_FEEDS" >/dev/null 2>&1 || true
  feeds_enabled || return 0
  feeds_interval_ok || die "AMPHORA_FEEDS_INTERVAL must be a whole number of seconds, at least 900"
  if link="$(feeds_inbox_link)"; then
    die "$link is a symlink — the feeds inbox must be a real folder; remove it and run again"
  fi
  mkdir -p "$FEEDS_INBOX/used" "$FEEDS_INBOX/done"
  bind_source_check "$FEEDS_INBOX" "AMPHORA_FEEDS_INBOX" || die "the feeds inbox must be inside a machine share"
  podman image exists "$IMG_FEEDS" || build_feeds
  podman network exists "$NET_FEEDS" 2>/dev/null || podman network create "$NET_FEEDS" >/dev/null
  podman volume exists "$VOL_FEEDS" 2>/dev/null || podman volume create "$VOL_FEEDS" >/dev/null
  podman run -d \
    --name "$C_FEEDS" \
    --label "$OWNER_LABEL=$STACK_DIR" \
    --network "$NET_FEEDS" \
    --restart unless-stopped \
    --read-only --cap-drop all --security-opt no-new-privileges \
    --memory 256m --pids-limit 64 \
    -e FEEDS_INTERVAL="$FEEDS_INTERVAL" \
    -v "$VOL_FEEDS:/state" \
    -v "$FEEDS_INBOX:/inbox" \
    "$IMG_FEEDS" >/dev/null
}

# What reaches a terminal from this container started as third-party text. fetch.py
# already strips control characters; this is the second time, on this side of the pipe.
feeds_print() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }

feeds_need_running() {
  running "$C_FEEDS" || die "$C_FEEDS is not running — amphoractl feeds push (or up)"
}

cmd_feeds() {
  need_podman
  case "${1:-ls}" in
    ls)
      feeds_need_running
      podman exec "$C_FEEDS" python /app/fetch.py --stats 2>&1 | feeds_print ;;
    held)
      case "${2:-20}" in *[!0-9]*) die "usage: amphoractl feeds held [n]" ;; esac
      feeds_need_running
      podman exec "$C_FEEDS" python /app/fetch.py --held ${2:+"$2"} 2>&1 | feeds_print ;;
    check)
      [ -n "${2:-}" ] || die "usage: amphoractl feeds check <url> [type [pattern]]"
      podman image exists "$IMG_FEEDS" || die "no $IMG_FEEDS yet — amphoractl feeds push"
      podman network exists "$NET_FEEDS" 2>/dev/null || die "no $NET_FEEDS yet — amphoractl feeds push"
      shift
      podman run --rm --network "$NET_FEEDS" \
        --read-only --cap-drop all --security-opt no-new-privileges \
        "$IMG_FEEDS" --check "$@" 2>&1 | feeds_print ;;
    push)
      owner_check
      feeds_list_check
      feeds_enabled || die "no active source in $FEEDS_FILE — start from etc/feeds.csv.example"
      echo "building the feeds image"
      build_feeds
      start_feeds
      c_grn "  $C_FEEDS recreated — it fetches now, then every ${FEEDS_INTERVAL}s" ;;
    run)
      owner_check
      feeds_need_running
      podman exec "$C_FEEDS" python /app/fetch.py --once 2>&1 | feeds_print ;;
    replay)
      # replay [n] [source], in either order: a bare number is n. The source name
      # reaches python as one argv element, never through a shell.
      local n=1 src=""
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          ''|*[!0-9]*) [ -z "$src" ] || die "usage: amphoractl feeds replay [n] [source]"
                       src="$1" ;;
          *)           n="$1" ;;
        esac
        shift
      done
      owner_check
      feeds_need_running
      if [ -n "$src" ]; then
        podman exec "$C_FEEDS" python /app/fetch.py --replay "$n" "$src" 2>&1 | feeds_print
      else
        podman exec "$C_FEEDS" python /app/fetch.py --replay "$n" 2>&1 | feeds_print
      fi
      podman exec "$C_FEEDS" python /app/fetch.py --once 2>&1 | feeds_print ;;
    *) die "usage: amphoractl feeds ls | held [n] | check <url> [type [pattern]] | push | run | replay [n] [source]" ;;
  esac
}

# Doctor's section. Echoes findings; returns 1 on a failure.
feeds_doctor() {
  local bad=0 age link want got
  echo "feeds"
  if feeds_list_stale; then
    c_red "  etc/feeds.tsv is the old tab-separated list and there is no $FEEDS_FILE —"
    c_red "  rewrite it as etc/feeds.csv (etc/feeds.csv.example), or the next up removes the fetcher"
    return 1
  fi
  if ! feeds_enabled; then
    if podman container exists "$C_FEEDS" 2>/dev/null; then
      c_ylw "  $C_FEEDS exists but $FEEDS_FILE has no active source — amphoractl up removes it"
    else
      info "off (no etc/feeds.csv)"
    fi
    return 0
  fi
  info "list    $FEEDS_FILE"
  info "inbox   $FEEDS_INBOX -> $SB_PROJECTS${FEEDS_INBOX#"$WORKSPACE_HOST"}"
  if ! feeds_interval_ok; then
    c_red "  AMPHORA_FEEDS_INTERVAL='$FEEDS_INTERVAL' — want whole seconds, at least 900"; bad=1
  fi
  if link="$(feeds_inbox_link)"; then
    c_red "  $link is a symlink — the agent could point the inbox somewhere else"; bad=1
  elif [ -d "$FEEDS_INBOX" ]; then
    if ! bind_source_check "$FEEDS_INBOX" "AMPHORA_FEEDS_INBOX" >/dev/null 2>&1; then
      c_red "  the inbox is outside every machine share — it would bind empty"; bad=1
    fi
  fi
  if ! running "$C_FEEDS"; then
    c_red "  $C_FEEDS not running — amphoractl feeds push"
    return 1
  fi
  want="$(feeds_list_sum)"
  got="$(podman image inspect "$IMG_FEEDS" --format "{{index .Labels \"$FEEDS_LIST_LABEL\"}}" 2>/dev/null || true)"
  if [ "$want" != "$got" ]; then
    c_ylw "  etc/feeds.csv has changed since the image was built — amphoractl feeds push"
  fi
  age="$(podman exec "$C_FEEDS" python /app/fetch.py --status-age 2>/dev/null | tr -d '\r' || true)"
  case "$age" in
    ''|-1|*[!0-9]*) c_ylw "  no completed fetch yet" ;;
    *)
      if [ "$age" -gt $((FEEDS_INTERVAL * 2)) ]; then
        c_red "  last completed fetch ${age}s ago — more than twice the interval; amphoractl logs feeds"
        bad=1
      else
        c_grn "  last completed fetch ${age}s ago"
      fi ;;
  esac
  if podman exec "$C_FEEDS" python /app/fetch.py --stats 2>/dev/null | grep -q ' FAILING '; then
    c_ylw "  sources failing — amphoractl feeds ls"
  fi
  # No listening port, so this is defence in depth rather than the boundary: nothing the
  # agent runs should share a network with a container parsing third-party input.
  if podman network inspect "$NET_FEEDS" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
       | grep -q "$C_DIND"; then
    c_red "  $C_DIND is on $NET_FEEDS — the sandbox shares a network with the feed parser"; bad=1
  fi
  if podman network inspect "$NET" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
       | grep -q "$C_FEEDS"; then
    c_red "  $C_FEEDS is on $NET — it must sit on $NET_FEEDS alone"; bad=1
  fi
  return $bad
}
