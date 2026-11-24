# shellcheck shell=bash
# Output helpers, podman and secret basics, and which checkout owns the stack.
# Sourced by bin/amphoractl, never run on its own.

# ----------------------------------------------------------------- helpers --
c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }
die()    { c_red "error: $*" >&2; exit 1; }

have_podman() { command -v podman >/dev/null 2>&1 || die "podman not found on PATH"; }

connection_exists() {
  podman system connection ls --format '{{.Name}}' 2>/dev/null | grep -qx -- "$CONNECTION"
}

# Every command that talks to the engine. A missing connection would otherwise surface as
# a podman error on the first call, naming nothing useful.
need_podman() {
  have_podman
  connection_exists && return 0
  die "no podman connection '$CONNECTION' — the machine '$MACHINE' does not exist yet.
  amphoractl shares prints the command that creates it (README: Prerequisites)"
}

secret_exists() { podman secret inspect "$1" >/dev/null 2>&1; }

require_secrets() {
  local pair name missing=""
  for pair in "${SECRET_MAP[@]}"; do
    name="${pair%%:*}"
    secret_exists "$name" || missing="$missing $name"
  done
  [ -z "$missing" ] || die "missing podman secret(s):$missing — run: amphoractl secrets set"
}

# Emits --secret flags. Callers MUST run require_secrets first: a die() inside a
# command substitution would only kill the subshell.
secret_args() {
  local pair name env
  for pair in "${SECRET_MAP[@]}"; do
    name="${pair%%:*}"; env="${pair##*:}"
    printf -- '--secret\n%s,type=env,target=%s\n' "$name" "$env"
  done
}

# s0:cN,cM with N < M <= 1023 and no leading zeros: the only shape podman hands out,
# and the canonical form SELinux reports back, which doctor compares as a string.
mcs_level_ok() {
  local a b
  case "$1" in
    s0:c[0-9]*,c[0-9]*) ;;
    *) return 1 ;;
  esac
  a="${1#s0:c}"; a="${a%%,*}"
  b="${1#*,c}"
  case "$a" in ''|*[!0-9]*|0?*) return 1 ;; esac
  case "$b" in ''|*[!0-9]*|0?*) return 1 ;; esac
  [ "$a" -lt "$b" ] && [ "$b" -le 1023 ]
}

running() { [ "$(podman inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = "true" ]; }

# GNU first, then BSD. Not the other way round: GNU `stat -f` is --file-system, so it
# takes %m for a filename and prints filesystem details for the real one, while BSD
# rejects -c outright and prints nothing. Empty output when neither works.
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true; }
file_size()  { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || true; }

# ------------------------------------------------------------------ owner --
# Container names are global to the podman machine, so every checkout on this Mac —
# the live install on main, a dev worktree — drives the same containers and volumes.
# Each long-lived container is labelled with the checkout that created it, and a
# command that would replace or stop the stack refuses to run from any other one.
# Read-only commands (status, doctor, logs) work from anywhere.
OWNER_LABEL="io.amphora.stack"

# The checkout that owns the running stack, or nothing when no container carries a
# label: a stack from before the label existed, or no stack at all.
stack_owner() {
  local c o
  for c in "$C_HERMES" "$C_DIND" "$C_SEARX" "$C_SIGNAL" "$C_SIGRELAY" "$C_MAIL"; do
    o="$(podman inspect -f "{{index .Config.Labels \"$OWNER_LABEL\"}}" "$c" 2>/dev/null | tr -d '\r' || true)"
    case "$o" in ''|'<no value>') continue ;; esac
    printf '%s' "$o"
    return 0
  done
  return 0
}

# An owner whose folder no longer holds a checkout — moved, renamed, deleted — is
# adopted rather than obeyed; otherwise moving the live install would lock it out of
# its own stack.
owner_check() {
  local owner
  owner="$(stack_owner)"
  [ -z "$owner" ] && return 0
  [ "$owner" = "$STACK_DIR" ] && return 0
  if [ ! -x "$owner/bin/amphoractl" ]; then
    c_ylw "the stack was started from $owner, which no longer holds a checkout — adopting it"
    return 0
  fi
  die "the running stack belongs to $owner, not this checkout ($STACK_DIR).
  Run this there, or promote your change to it: amphoractl promote (in $owner)"
}

# Research projects carry a shim that finds the canonical checker by walking up to the
# checkout's tools/. With the runtime outside the checkout that walk never reaches it,
# so the runtime root names the checkout instead. The runtime root is not a share, so
# nothing in the sandbox can read or rewrite this pointer.
write_stack_pointer() {
  [ "$RUNTIME_DIR" = "$STACK_DIR" ] && return 0
  mkdir -p "$RUNTIME_DIR"
  printf '%s\n' "$STACK_DIR" > "$RUNTIME_DIR/.amphora-stack"
}

# The folders the stack owns and binds. `shares` makes them before printing the init line
# (it leaves out any source that does not exist, so on a fresh install the machine would
# be created without them) and `up` makes them again. User-supplied sources — the vault
# board, etc/mounts — are never created: a missing one is more likely a typo.
ensure_runtime_dirs() {
  mkdir -p "$WORKSPACE_HOST" "$OUTBOX_HOST"
}

vault_kanban_enabled() { [ -n "$VAULT_KANBAN" ]; }

