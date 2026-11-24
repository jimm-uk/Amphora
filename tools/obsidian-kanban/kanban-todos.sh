#!/usr/bin/env bash
# kanban-todos.sh — sweep tagged Obsidian notes onto a Kanban board, and schedule it.
#
# An optional module, gated entirely on AMPHORA_VAULT in etc/amphora.local: unset, every
# subcommand says so and exits cleanly. See README.md beside this file.
#
# Deliberately NOT under projects/: the scheduled sweep runs on the Mac as the user,
# outside every container, so a script the sandboxed agent could rewrite must not be
# what launchd executes.
#
#   kanban-todos.sh init
#   kanban-todos.sh run [--overdue-only] [--dry-run] [--no-writeback]
#   kanban-todos.sh schedule on [--overdue-only] [--at HH:MM | --every MINUTES]
#   kanban-todos.sh schedule off
#   kanban-todos.sh schedule status

set -euo pipefail

# Derived from where this script lives, so the stack stays checkout-path independent.
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"

# One config file for the whole stack, not a second surface to keep in sync.
if [ -f "$STACK_DIR/etc/amphora.local" ]; then
  # shellcheck disable=SC1091
  . "$STACK_DIR/etc/amphora.local"
fi

# Settings from before the rename to Amphora are refused rather than ignored: an old
# HERMES_VAULT that nothing reads would switch the sweep off without a word.
if [ -f "$STACK_DIR/etc/hermes.local" ] || [ -n "${HERMES_VAULT+set}" ] \
   || [ -n "${HERMES_VAULT_KANBAN+set}" ] || [ -n "${HERMES_VAULT_BOARD+set}" ] \
   || [ -n "${HERMES_LOG_DIR+set}" ]; then
  printf '\033[31merror: settings from before the rename to Amphora — etc/hermes.local is now etc/amphora.local, and HERMES_VAULT* / HERMES_LOG_DIR are AMPHORA_*. bin/amphoractl lists every rename.\033[0m\n' >&2
  exit 1
fi

VAULT_ROOT="${AMPHORA_VAULT:-}"
VAULT_KANBAN="${VAULT_ROOT:+${AMPHORA_VAULT_KANBAN:-$VAULT_ROOT/Kanban}}"
BOARD_NAME="${AMPHORA_VAULT_BOARD:-Board.md}"
SWEEP="$HERE/surface_todos.py"

LABEL="local.amphora.todos"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
# Overridable like every other path the stack writes to (cf. AMPHORA_BACKUP_DIR), and
# by default in the runtime folder beside the snapshots — <runtime>/logs, which is the
# checkout's own gitignored logs/ when AMPHORA_RUNTIME_DIR is unset.
LOG_DIR="${AMPHORA_LOG_DIR:-${AMPHORA_RUNTIME_DIR:-$STACK_DIR}/logs}"
LOG="$LOG_DIR/todos.log"

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }
die()    { c_red "$*"; exit 1; }

# Not configured is a normal state on a machine without the vault, not a failure:
# exit 0 so a stale LaunchAgent on a reconfigured machine goes quiet instead of
# mailing you a failure every morning.
vault_configured() {
  if [ -z "$VAULT_ROOT" ]; then
    echo "AMPHORA_VAULT is not set in etc/amphora.local — nothing to sweep on this machine."
    return 1
  fi
  return 0
}

# Separate from the above on purpose. Unset means "this machine does not do Obsidian".
# Set but missing means something is wrong — an unmounted volume, a renamed folder —
# and that deserves a message rather than silence.
vault_present() {
  if [ ! -d "$VAULT_ROOT" ]; then
    c_ylw "vault not found at $VAULT_ROOT — skipping this run"
    info "if the vault has moved, update AMPHORA_VAULT in etc/amphora.local"
    return 1
  fi
  if [ ! -f "$VAULT_KANBAN/$BOARD_NAME" ]; then
    c_ylw "no board at $VAULT_KANBAN/$BOARD_NAME — skipping this run"
    info "seed it: cp '$HERE/Board.template.md' '$VAULT_KANBAN/$BOARD_NAME'"
    return 1
  fi
  return 0
}

# The plist is the ONE thing this module puts outside the stack folder, and it has to
# name an absolute path. So moving or renaming the checkout leaves launchd pointing at
# a script that is no longer there — and launchd fails that silently, once a day,
# forever. Nothing can prevent it; the answer is to notice it out loud.
plist_target() {
  [ -f "$PLIST" ] || return 1
  sed -n 's|.*<string>\(/.*kanban-todos\.sh\)</string>.*|\1|p' "$PLIST" | head -1
}

# One field out of the StartCalendarInterval dict, 0 if absent. Scoped to that dict so
# it cannot pick up an integer from elsewhere in the plist.
calendar_int() {
  local v
  v="$(sed -n "/StartCalendarInterval/,/<\/dict>/s|.*<key>$1</key><integer>\([0-9]*\)</integer>.*|\1|p" "$PLIST")"
  printf '%s\n' "${v:-0}"
}

# "every 15 minutes --overdue-only", or "daily at 08:00". Reads the plist rather than
# remembering what was asked for, so it describes what will actually fire.
schedule_phrase() {
  local flags secs when
  flags="$(sed -n 's|.*<string>\(--[a-z-]*\)</string>.*|\1|p' "$PLIST" | tr '\n' ' ')"
  flags="${flags% }"
  secs="$(sed -n 's|.*<key>StartInterval</key><integer>\([0-9]*\)</integer>.*|\1|p' "$PLIST")"
  if [ -n "$secs" ]; then
    when="every $((secs / 60)) minutes"
  else
    when="$(printf 'daily at %02d:%02d' \
      "$(calendar_int Hour)" "$(calendar_int Minute)")"
  fi
  printf '%s%s\n' "$when" "${flags:+ $flags}"
}

# The timestamp off the most recent run header — which is why those headers exist.
# `pipefail` is on, so a grep that matches nothing fails the whole pipeline and, under
# `set -e`, takes the script with it. A log that predates the headers is the normal
# case for exactly one day after upgrading, so it must return empty, not die.
last_run_stamp() {
  [ -s "$LOG" ] || return 0
  local line=""
  line="$(grep '^=== ' "$LOG" 2>/dev/null | tail -1)" || true
  [ -n "$line" ] || return 0
  printf '%s\n' "$line" | sed 's|^=== \(.*\)  sweep.*|\1|'
}

# Fallback for a log written before run headers existed. The file's mtime is when the
# last run wrote to it, which is the honest answer even though it is not the run's own
# clock. `date -r` reads a file's mtime on both BSD and GNU date.
log_mtime() {
  [ -s "$LOG" ] || return 0
  date -r "$LOG" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || true
}

plist_is_stale() {
  local target
  target="$(plist_target)" || return 1
  [ -n "$target" ] && [ "$target" != "$SELF" ]
}

require_launchd() {
  [ "$(uname -s)" = "Darwin" ] || die "scheduling is launchd, so macOS only — this is $(uname -s).
  On Linux, call 'kanban-todos.sh run' from whatever timer that box already uses."
  command -v launchctl >/dev/null 2>&1 || die "launchctl not found"
}

# Seeds the board folder. Separate from `run` so a sweep can never create a board:
# a missing board means something is wrong (unmounted volume, renamed folder) and
# silently making a fresh empty one would hide that and lose the real board's columns.
cmd_init() {
  vault_configured || return 1
  [ -d "$VAULT_ROOT" ] || die "vault not found at $VAULT_ROOT"
  mkdir -p "$VAULT_KANBAN"
  local board="$VAULT_KANBAN/$BOARD_NAME"
  if [ -e "$board" ]; then
    info "board already exists: $board"
  else
    cp "$HERE/Board.template.md" "$board"
    c_grn "created $board"
  fi
  # Refreshed every time: these are the agent's rules, and a stale copy is worse than
  # none. Nothing else in the folder is ever overwritten.
  cp "$HERE/AGENT.md" "$VAULT_KANBAN/AGENT.md"
  c_grn "wrote  $VAULT_KANBAN/AGENT.md"
  info "the agent reads that file at /mounts/kanban/AGENT.md"
}

cmd_run() {
  local extra=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --overdue-only|--dry-run|--no-writeback) extra+=("$1") ;;
      *) die "usage: kanban-todos.sh run [--overdue-only] [--dry-run] [--no-writeback]" ;;
    esac
    shift
  done
  # launchd appends every run to one file, so a repeating sweep is otherwise an
  # undifferentiated wall. Printed before the guards, not after: a run that skips
  # because the vault is missing is exactly the one you want dated. One header line
  # rather than a per-line prefix — the sweep's own output is a listing and prefixing
  # it would wreck it.
  local stamp
  stamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  if [ ${#extra[@]} -gt 0 ]; then
    printf '\n=== %s  sweep %s ===\n' "$stamp" "${extra[*]}"
  else
    printf '\n=== %s  sweep ===\n' "$stamp"
  fi
  vault_configured || return 0
  vault_present    || return 0
  if plist_is_stale; then
    c_ylw "note: the scheduled sweep still points at $(plist_target)"
    info "re-run 'kanban-todos.sh schedule on' to point it at this checkout"
  fi
  python3 "$SWEEP" "$VAULT_ROOT" --sync "$VAULT_KANBAN/$BOARD_NAME" \
    ${extra[@]+"${extra[@]}"}
}

# $1 is the plist fragment naming when to fire — a StartCalendarInterval dict for a
# daily run, or StartInterval seconds for a repeating one. Built by the caller so this
# function stays the one place that knows the plist's shape.
write_plist() {
  local when="$1"; shift
  local args=""
  local a
  for a in "$@"; do
    args="$args    <string>$a</string>"$'\n'
  done
  mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"
  # Generated here and never committed: it carries this machine's absolute paths, which
  # is exactly the kind of thing that must not travel with the repo.
  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SELF</string>
    <string>run</string>
$args  </array>
$when
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
PLIST_EOF
}

cmd_schedule() {
  case "${1:-}" in
    on)
      shift
      local at="08:00"
      local every=""
      local flags=()
      while [ $# -gt 0 ]; do
        case "$1" in
          --overdue-only) flags+=("$1"); shift ;;
          --at) at="${2:-}"; every=""; shift 2 ;;
          --every) every="${2:-}"; shift 2 ;;
          *) die "usage: kanban-todos.sh schedule on [--overdue-only] [--at HH:MM | --every MINUTES]" ;;
        esac
      done
      local when
      if [ -n "$every" ]; then
        # A repeating sweep rather than a daily one. Worth knowing what it costs: every
        # firing is another go at a race with the Kanban plugin that nothing can lock.
        # It is cheap because a run that changes nothing now writes nothing at all, so
        # the board and its backup are only touched when there is something to touch.
        [[ "$every" =~ ^[0-9]+$ ]] || die "--every wants whole minutes, got '$every'"
        [ "$every" -ge 5 ] || die "--every below 5 minutes is a busy loop over your vault"
        when="  <key>StartInterval</key><integer>$((every * 60))</integer>"
      else
        [[ "$at" =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || die "--at wants HH:MM, got '$at'"
        local hh="${at%%:*}" mm="${at##*:}"
        when="  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>$((10#$hh))</integer>
    <key>Minute</key><integer>$((10#$mm))</integer>
  </dict>"
      fi
      require_launchd
      vault_configured || die "refusing to schedule a sweep with no vault configured"
      [ -d "$VAULT_ROOT" ] || die "vault not found at $VAULT_ROOT"

      # A LaunchAgent rather than cron: it fires on wake if the Mac was asleep at the
      # scheduled time, which cron does not. Same reasoning as `amphoractl backup schedule`.
      write_plist "$when" ${flags[@]+"${flags[@]}"}
      launchctl unload "$PLIST" >/dev/null 2>&1 || true
      launchctl load "$PLIST"
      if [ -n "$every" ]; then
        c_grn "sweep every $every minute(s) ${flags[*]:-}"
      else
        c_grn "daily sweep at $at ${flags[*]:-}"
      fi
      info "plist  $PLIST"
      info "log    $LOG" ;;
    off)
      require_launchd
      launchctl unload "$PLIST" >/dev/null 2>&1 || true
      rm -f "$PLIST"
      c_grn "scheduled sweep removed"
      info "nothing of it remains but $LOG, which you can delete" ;;
    status)
      shift
      local verbose=0
      case "${1:-}" in
        -v|--verbose) verbose=1 ;;
        "") ;;
        *) die "usage: kanban-todos.sh schedule status [-v]" ;;
      esac
      require_launchd
      if [ ! -f "$PLIST" ]; then
        echo "not scheduled"
        return 0
      fi

      # The question this command exists to answer is "is it on, and how often".
      # That is line one. Everything else is diagnostics and lives behind -v.
      printf '%s\n' "$(schedule_phrase)"
      if plist_is_stale; then
        c_red "STALE — points at $(plist_target), not this checkout"
        info "fix: kanban-todos.sh schedule on"
      elif ! launchctl list "$LABEL" >/dev/null 2>&1; then
        c_ylw "not loaded — kanban-todos.sh schedule on"
      fi
      # An `if`, not `[ ... ] && ...`: under `set -e` a bare AND-list that tests false
      # is a non-zero statement, and the script exits there. That bug shipped once.
      local last
      last="$(last_run_stamp)"
      if [ -n "$last" ]; then
        info "last run $last"
      else
        # No header does not mean no run: the log may predate the headers, in which
        # case saying "not run yet" about a sweep that ran this morning is a lie.
        local mtime
        mtime="$(log_mtime)"
        if [ -n "$mtime" ]; then
          info "last run $mtime (from the log's mtime — it predates run headers)"
        else
          info "never run"
        fi
      fi

      [ "$verbose" = 1 ] || return 0
      local lines=0
      [ -f "$LOG" ] && lines="$(wc -l < "$LOG" | tr -d ' ')" || true
      info "plist    $PLIST"
      info "log      $LOG ($lines lines, unrotated)"
      if [ -s "$LOG" ]; then
        echo "last run output:"
        # Everything since the most recent header, so this shows one whole run rather
        # than the last five lines of however many. Bounded, in case a run was noisy.
        tail -n 200 "$LOG" \
          | awk '/^=== /{buf=""} {buf = buf $0 ORS} END{printf "%s", buf}' \
          | sed 's/^/  /'
      fi ;;
    *) die "usage: kanban-todos.sh schedule [on|off|status]" ;;
  esac
}

case "${1:-}" in
  init)     shift; cmd_init "$@" ;;
  run)      shift; cmd_run "$@" ;;
  schedule) shift; cmd_schedule "$@" ;;
  *)
    cat <<USAGE
kanban-todos.sh — sweep tagged Obsidian notes onto the kanban board

  init                                  seed the board folder in the vault
  run [--overdue-only] [--dry-run] [--no-writeback]   sweep now
  schedule on [--overdue-only] [--at HH:MM | --every MINUTES]
                                        daily LaunchAgent (default 08:00), or repeating
  schedule off                          remove it
  schedule status [-v]                  is it on and how often; -v adds paths and log

Everything is gated on AMPHORA_VAULT in etc/amphora.local. Unset, every subcommand
exits cleanly having done nothing — which is what a machine without the vault wants.
USAGE
    exit 1 ;;
esac
