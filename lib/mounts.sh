# shellcheck shell=bash
# etc/mounts and every directory the agent can reach; `mount`.
# Sourced by bin/amphoractl, never run on its own.

# ------------------------------------------------------------------ mounts --
# etc/mounts is read, never sourced. A list of folders is data; sourcing it would make
# every extra folder an arbitrary-code entry point for anything that can write the file,
# which is the opposite of what the list is for.
#
# One entry per line, `name<TAB>path[<TAB>ro]`, # comments and blank lines ignored.
# Spaces work as separators too, but a path containing spaces needs the tabs — which is
# what `mount add` always writes. A leading ~/ is expanded; nothing else is.
MOUNT_NAMES=(); MOUNT_PATHS=(); MOUNT_MODES=(); MOUNT_BIND_ARGS=()
# Counted rather than read back with ${#a[@]}: bash 3.2 is inconsistent about an empty
# array under `set -u`, and this list is empty on most machines.
MOUNT_COUNT=0

mounts_parse() {
  [ -f "$MOUNTS_FILE" ] || return 0
  awk '
    BEGIN { FS = "\t" }
    { sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
    /^#/ { next }
    /^$/ { next }
    {
      name = ""; path = ""; mode = ""
      if (NF >= 2) {
        name = $1; path = $2; if (NF >= 3) mode = $3
      } else {
        n = split($0, f, /[ \t]+/)
        if (n < 2) { printf "  ignoring malformed line %d of mounts: %s\n", NR, $0 > "/dev/stderr"; next }
        name = f[1]
        if (f[n] == "ro") { mode = "ro"; n-- }
        path = f[2]
        for (i = 3; i <= n; i++) path = path " " f[i]
      }
      if (name == "" || path == "") next
      printf "%s\t%s\t%s\n", name, path, mode
    }
  ' "$MOUNTS_FILE"
}

load_mounts() {
  MOUNT_NAMES=(); MOUNT_PATHS=(); MOUNT_MODES=(); MOUNT_COUNT=0
  local n p m
  while IFS=$'\t' read -r n p m; do
    [ -n "$n" ] || continue
    case "$p" in "~/"*) p="$HOME/${p#\~/}" ;; esac
    MOUNT_NAMES+=("$n"); MOUNT_PATHS+=("$p"); MOUNT_MODES+=("$m")
    MOUNT_COUNT=$((MOUNT_COUNT + 1))
  done <<EOF
$(mounts_parse)
EOF
}

# The same in dind and in the sandbox, on purpose: a path means one thing at every hop.
mount_sandbox_path() { printf '%s/%s' "$SB_MOUNTS" "$1"; }
mount_dind_path()    { mount_sandbox_path "$1"; }

# Fills MOUNT_BIND_ARGS for start_dind. A source that has gone missing is warned about
# and skipped rather than fatal: a renamed folder should cost you that folder, not the
# whole stack. doctor reports the gap in red.
build_mount_binds() {
  MOUNT_BIND_ARGS=()
  local i=0 n p m
  while [ "$i" -lt "$MOUNT_COUNT" ]; do
    n="${MOUNT_NAMES[$i]}"; p="${MOUNT_PATHS[$i]}"; m="${MOUNT_MODES[$i]}"
    i=$((i + 1))
    if ! bind_source_check "$p" "mount '$n'"; then
      c_ylw "  skipping '$n' — the agent will not see $(mount_sandbox_path "$n")"
      continue
    fi
    if [ "$m" = "ro" ]; then
      MOUNT_BIND_ARGS+=(-v "$p:$(mount_dind_path "$n"):ro")
    else
      MOUNT_BIND_ARGS+=(-v "$p:$(mount_dind_path "$n")")
    fi
  done
}

# The one place that knows every directory the agent can reach, so `mount ls`, doctor
# and the generated config block cannot disagree about it.
EX_HOST=(); EX_DIND=(); EX_SB=(); EX_MODE=()
build_exposures() {
  load_mounts
  EX_HOST=("$WORKSPACE_HOST"); EX_SB=("$SB_PROJECTS"); EX_MODE=("rw")
  EX_HOST+=("$OUTBOX_HOST");   EX_SB+=("$SB_OUTBOX");  EX_MODE+=("rw")
  if vault_kanban_enabled; then
    EX_HOST+=("$VAULT_KANBAN"); EX_SB+=("$SB_KANBAN"); EX_MODE+=("rw")
  fi
  local i=0
  while [ "$i" -lt "$MOUNT_COUNT" ]; do
    EX_HOST+=("${MOUNT_PATHS[$i]}")
    EX_SB+=("$(mount_sandbox_path "${MOUNT_NAMES[$i]}")")
    if [ "${MOUNT_MODES[$i]}" = "ro" ]; then EX_MODE+=("ro"); else EX_MODE+=("rw"); fi
    i=$((i + 1))
  done
  EX_DIND=("${EX_SB[@]}")
}

print_exposures() {
  # Widths from the content, not fixed: a mount named after a real folder overflows any
  # column you pick in advance, and a ragged table is harder to read than a wide one.
  local i=0 suffix w1=10
  while [ "$i" -lt "${#EX_SB[@]}" ]; do
    if [ "${#EX_SB[$i]}" -gt "$w1" ]; then w1="${#EX_SB[$i]}"; fi
    i=$((i + 1))
  done
  printf '  %-*s  %s\n' "$w1" "AGENT SEES" "ON THIS MAC"
  i=0
  while [ "$i" -lt "${#EX_SB[@]}" ]; do
    if [ "${EX_MODE[$i]}" = "ro" ]; then suffix="  (read-only)"; else suffix=""; fi
    printf '  %-*s  %s%s\n' "$w1" "${EX_SB[$i]}" "${EX_HOST[$i]}" "$suffix"
    i=$((i + 1))
  done
}

# Everything else on this machine is invisible to the agent by construction, and a few
# folders have to stay that way: bin/ is what launchd runs, etc/amphora.local holds the
# phone numbers, and backups/ is a byte-for-byte copy of everything the agent has ever
# been told. Exposing a folder that contains any of them hands it all three, so these
# are refused outright rather than warned about. Echoes what was refused; 0 = refused.
mount_source_refusal() {
  local p="$1"
  if [ "$p" = "$HOME" ]; then echo "your whole home directory"; return 0; fi
  case "$STACK_DIR/" in "$p"/*) echo "a folder containing the stack itself ($STACK_DIR)"; return 0 ;; esac
  case "$p/" in "$STACK_DIR"/*) echo "part of the stack folder — bin/, etc/ and backups/ are above the mount on purpose"; return 0 ;; esac
  case "$BACKUP_DIR/" in "$p"/*) echo "a folder containing the volume snapshots ($BACKUP_DIR)"; return 0 ;; esac
  case "$p/" in "$WORKSPACE_HOST"/*) echo "a folder already inside the projects tree"; return 0 ;; esac
  case "$OUTBOX_HOST/" in "$p"/*) echo "a folder containing the outbox ($OUTBOX_HOST)"; return 0 ;; esac
  case "$p/" in "$OUTBOX_HOST"/*) echo "part of the outbox, which is already mounted"; return 0 ;; esac
  case "$RUNTIME_DIR/" in "$p"/*) echo "a folder containing the runtime folder ($RUNTIME_DIR)"; return 0 ;; esac
  case "$p/" in "$RUNTIME_DIR"/*) echo "part of the runtime folder — snapshots and logs sit above the mount on purpose"; return 0 ;; esac
  if vault_kanban_enabled; then
    case "$VAULT_ROOT/" in "$p"/*) echo "the Obsidian vault — only <vault>/Kanban crosses, and that is deliberate"; return 0 ;; esac
  fi
  return 1
}

mount_name_ok() {
  case "$1" in
    kanban|outbox) return 1 ;;
    ''|.*|-*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

mount_add() {
  local path="" name="" mode="" i
  while [ $# -gt 0 ]; do
    case "$1" in
      --ro) mode="ro" ;;
      --rw) mode="" ;;
      -*)   die "unknown flag: $1" ;;
      *)
        if   [ -z "$path" ]; then path="$1"
        elif [ -z "$name" ]; then name="$1"
        else die "usage: amphoractl mount add <path> [name] [--ro]"
        fi ;;
    esac
    shift
  done
  [ -n "$path" ] || die "usage: amphoractl mount add <path> [name] [--ro]"
  case "$path" in "~/"*) path="$HOME/${path#\~/}" ;; esac
  [ -d "$path" ] || die "'$path' is not a directory"
  # Canonicalised before anything else looks at it: the bind is resolved inside the VM,
  # and a path reached through a symlink or a .. is not the folder you think it is —
  # which matters, because the refusals below are prefix comparisons.
  path="$(cd "$path" && pwd -P)"
  # A folder the machine does not share yet is accepted, not refused: it has to be in
  # the list before `amphoractl shares` can put it in a replacement machine. `up` skips
  # it and doctor fails until then.
  local share_state="shared"
  if ! load_machine_shares; then
    share_state="unknown"
  elif ! under_share "$path"; then
    share_state="outside"
  fi
  local why
  if why="$(mount_source_refusal "$path")"; then
    die "refusing to expose $why"
  fi

  if [ -z "$name" ]; then
    name="$(basename "$path" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
  fi
  mount_name_ok "$name" \
    || die "'$name' will not do as a folder name under $SB_MOUNTS — pass one explicitly"
  load_mounts
  i=0
  while [ "$i" -lt "$MOUNT_COUNT" ]; do
    if [ "${MOUNT_NAMES[$i]}" = "$name" ]; then
      die "a mount named '$name' already exists — amphoractl mount rm $name"
    fi
    i=$((i + 1))
  done

  if [ ! -f "$MOUNTS_FILE" ]; then
    mkdir -p "$(dirname "$MOUNTS_FILE")"
    {
      printf '# Folders exposed to the Hermes agent, beyond projects/.\n'
      printf '# Managed by `amphoractl mount add|rm|ls`. One per line: name<TAB>path[<TAB>ro]\n'
      printf '# Each becomes /mounts/<name> in the sandbox. Not sourced as shell.\n'
    } > "$MOUNTS_FILE"
  fi
  if [ -n "$mode" ]; then
    printf '%s\t%s\t%s\n' "$name" "$path" "$mode" >> "$MOUNTS_FILE"
  else
    printf '%s\t%s\n' "$name" "$path" >> "$MOUNTS_FILE"
  fi
  c_grn "added: $path  ->  $(mount_sandbox_path "$name")${mode:+  (read-only)}"
  case "$share_state" in
    shared)
      info "not live yet — the bind is fixed when dind is created: amphoractl up" ;;
    outside)
      c_ylw "  the podman machine does not share this folder, so it cannot be bound yet"
      info "shares are fixed when the machine is created — amphoractl shares, then"
      info "README.md, 'Narrowing the machine's shares'. Until then 'up' skips it."
      ;;
    *)
      c_ylw "  could not ask the podman machine whether it shares this folder"
      info "'up' and doctor check it; amphoractl shares lists what the machine needs" ;;
  esac
}

# Anything that identifies a mount resolves to its name: the name itself, the folder on
# the Mac in whatever spelling you used with `mount add`, or the container path that
# `mount ls` prints. The name appears in that listing only buried inside /mounts/<name>,
# so making it the only accepted argument meant asking you to pick it back out by eye.
# Echoes the name; 1 if nothing matches. Requires load_mounts first.
mount_resolve() {
  local want="$1" i=0 n p cw cp
  case "$want" in */) want="${want%/}" ;; esac
  case "$want" in "~/"*) want="$HOME/${want#\~/}" ;; esac
  # Canonicalised only when it still exists — a mount whose folder has been deleted or
  # renamed is exactly the one you most need to be able to remove.
  cw=""
  if [ -d "$want" ]; then cw="$(cd "$want" && pwd -P)"; fi
  while [ "$i" -lt "$MOUNT_COUNT" ]; do
    n="${MOUNT_NAMES[$i]}"; p="${MOUNT_PATHS[$i]}"
    i=$((i + 1))
    if [ "$want" = "$n" ] \
       || [ "$want" = "$(mount_sandbox_path "$n")" ] \
       || [ "$want" = "$(mount_dind_path "$n")" ] \
       || [ "$want" = "$p" ]; then
      printf '%s' "$n"; return 0
    fi
    if [ -n "$cw" ] && [ -d "$p" ]; then
      cp="$(cd "$p" && pwd -P)"
      if [ "$cw" = "$cp" ]; then printf '%s' "$n"; return 0; fi
    fi
  done
  return 1
}

mount_rm() {
  local want="${1:-}" name tmp
  [ -n "$want" ] || die "usage: amphoractl mount rm <name | path>"
  [ -f "$MOUNTS_FILE" ] || die "no mounts configured — $MOUNTS_FILE does not exist"
  load_mounts
  name="$(mount_resolve "$want")" \
    || die "nothing configured matches '$want' — amphoractl mount ls"
  tmp="$MOUNTS_FILE.tmp.$$"
  awk -v want="$name" '
    BEGIN { FS = "\t" }
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^[ \t]*#/ { print; next }
    line ~ /^[ \t]*$/ { print; next }
    {
      n = $1
      if (NF < 2) { split(line, f, /[ \t]+/); n = f[1] }
      gsub(/^[ \t]+|[ \t]+$/, "", n)
      if (n == want) next
      print
    }
  ' "$MOUNTS_FILE" > "$tmp"
  mv "$tmp" "$MOUNTS_FILE"
  c_grn "removed '$name'  ($(mount_sandbox_path "$name"))"
  info "still mounted in the running stack until: amphoractl up"
}

cmd_mount() {
  local sub="${1:-ls}"
  shift || true
  case "$sub" in
    ls)   build_exposures; print_exposures
          echo
          info "everything else on this Mac is invisible to the agent"
          info "verify what actually arrived: amphoractl doctor" ;;
    add)  mount_add ${1+"$@"} ;;
    rm)   mount_rm "${1:-}" ;;
    *)    die "usage: amphoractl mount [ls | add <path> [name] [--ro] | rm <name|path>]" ;;
  esac
}
