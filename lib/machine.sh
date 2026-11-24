# shellcheck shell=bash
# The podman machine: its shares, what a bind needs from them, and `shares`.
# Sourced by bin/amphoractl, never run on its own.

# ---------------------------------------------------------- machine shares --
# The folders the podman machine shares into its VM are the real security boundary:
# root in the VM reads and writes all of them, as you. They are fixed at
# `podman machine init`, and podman's macOS default is /Users, /private and
# /var/folders — every home directory on the Mac. `amphoractl shares` prints the
# narrow list this stack needs; see THREAT-MODEL.md before widening it.
#
# Read from the VM's own mount table rather than from podman's machine config, for the
# same reason doctor reads mounts back off the sandbox: it is what actually arrived.
# amphoractl hands Mac paths to the VM unchanged, so each share must have identical
# source and target — the VM path is then the Mac path, and that is what is compared.
MACHINE_SHARES=(); MACHINE_SHARE_COUNT=0; MACHINE_SHARES_READ=0

# The machine's name when it exists, nothing otherwise.
machine_name() { podman machine inspect "$MACHINE" --format '{{.Name}}' 2>/dev/null | head -1 || true; }
machine_field() { podman machine inspect "$MACHINE" --format "$1" 2>/dev/null | head -1 || true; }

# 1 when the VM cannot be asked. Cached: `podman machine ssh` costs about a second.
load_machine_shares() {
  if [ "$MACHINE_SHARES_READ" = 1 ]; then return 0; fi
  local name raw list t
  name="$(machine_name)"
  if [ -z "$name" ]; then return 1; fi
  # The machine is named explicitly: with no name, podman guesses whether the first
  # word is a machine or the command.
  raw="$(podman machine ssh "$name" cat /proc/mounts 2>/dev/null | tr -d '\r' || true)"
  # Every mount table has a root entry. Without one this is not a mount table.
  case "$raw" in *" / "*) : ;; *) return 1 ;; esac
  # /proc/mounts escapes a space as \040 and a backslash as \134. Anything stranger
  # stays escaped, never matches, and so fails closed.
  list="$(printf '%s\n' "$raw" | awk '$3 == "virtiofs" || $3 == "9p" { print $2 }' \
    | sed -e 's/\\040/ /g' -e 's/\\134/\\/g' || true)"
  MACHINE_SHARES=(); MACHINE_SHARE_COUNT=0
  while IFS= read -r t; do
    if [ -n "$t" ]; then
      MACHINE_SHARES+=("$t")
      MACHINE_SHARE_COUNT=$((MACHINE_SHARE_COUNT + 1))
    fi
  done <<EOF
$list
EOF
  MACHINE_SHARES_READ=1
  return 0
}

# 0 when a canonical Mac path lies inside a share. Requires load_machine_shares.
under_share() {
  local p="$1" t i=0
  while [ "$i" -lt "$MACHINE_SHARE_COUNT" ]; do
    t="${MACHINE_SHARES[$i]}"
    i=$((i + 1))
    if [ "$t" = "/" ]; then return 0; fi
    case "$p" in "$t"|"$t"/*) return 0 ;; esac
  done
  return 1
}

# 0 when the share would expose your whole home folder, or the stack's own files.
share_too_wide() {
  local t="$1"
  case "$HOME/" in "$t"/*) return 0 ;; esac
  case "$STACK_DIR/" in "$t"/*) return 0 ;; esac
  case "$BACKUP_DIR/" in "$t"/*) return 0 ;; esac
  case "$RUNTIME_DIR/" in "$t"/*) return 0 ;; esac
  if [ "$t" = "/" ]; then return 0; fi
  return 1
}

# A bind whose source does not exist, or which the machine VM cannot see, does not
# fail — dind creates an empty directory and the agent quietly finds nothing there.
# That failure mode has cost enough time on this stack already, so refuse up front.
# Silent and 0 when the path is usable. Fails closed when the VM cannot be asked.
bind_source_check() {
  local path="$1" what="$2" canon
  if [ ! -d "$path" ]; then
    c_red "$what points at '$path', which is not a directory"
    return 1
  fi
  if ! load_machine_shares; then
    c_red "$what: could not read the podman machine's shared folders"
    info "is the machine running? podman machine start $MACHINE"
    return 1
  fi
  canon="$(cd "$path" && pwd -P)"
  if ! under_share "$canon"; then
    c_red "$what ($canon) is outside every folder the podman machine shares"
    info "a path the VM cannot see binds as an empty directory with no error at all"
    info "shares are fixed when the machine is created — amphoractl shares"
    return 1
  fi
  return 0
}

vault_kanban_check() {
  if bind_source_check "$VAULT_KANBAN" "AMPHORA_VAULT_KANBAN"; then return 0; fi
  if [ ! -d "$VAULT_KANBAN" ]; then
    info "create it, or unset AMPHORA_VAULT in etc/amphora.local"
  fi
  return 1
}

machine_running() { [ "$(machine_field '{{.State}}')" = "running" ]; }

# ------------------------------------------------------------------ shares --
# Every Mac folder a container binds, canonical, with anything nested inside another
# entry dropped. A folder that does not exist is left out; `up` and doctor report it.
REQ_SHARES=(); REQ_SHARE_COUNT=0
build_required_shares() {
  build_exposures
  REQ_SHARES=(); REQ_SHARE_COUNT=0
  local -a cands=()
  local nc=0 i=0 j p q keep
  while [ "$i" -lt "${#EX_HOST[@]}" ]; do
    p="${EX_HOST[$i]}"
    i=$((i + 1))
    if [ -d "$p" ]; then
      cands+=("$(cd "$p" && pwd -P)")
      nc=$((nc + 1))
    fi
  done
  i=0
  while [ "$i" -lt "$nc" ]; do
    p="${cands[$i]}"; keep=1; j=0
    while [ "$j" -lt "$nc" ]; do
      q="${cands[$j]}"
      if [ "$j" -ne "$i" ]; then
        case "$p" in "$q"/*) keep=0 ;; esac
        if [ "$p" = "$q" ] && [ "$j" -lt "$i" ]; then keep=0; fi
      fi
      j=$((j + 1))
    done
    if [ "$keep" = 1 ]; then
      REQ_SHARES+=("$p")
      REQ_SHARE_COUNT=$((REQ_SHARE_COUNT + 1))
    fi
    i=$((i + 1))
  done
}

cmd_shares() {
  have_podman
  ensure_runtime_dirs
  build_required_shares
  local i=0 p t have=0 need name res="" cpus="" mem="" disk="" guessed=0 provider
  if load_machine_shares; then have=1; fi

  echo "folders this stack binds into containers"
  while [ "$i" -lt "$REQ_SHARE_COUNT" ]; do
    p="${REQ_SHARES[$i]}"
    i=$((i + 1))
    if [ "$have" = 0 ]; then
      info "$p"
    elif under_share "$p"; then
      c_grn "  $p"
    else
      c_red "  $p  (not shared)"
    fi
  done
  i=0
  while [ "$i" -lt "${#EX_HOST[@]}" ]; do
    p="${EX_HOST[$i]}"
    i=$((i + 1))
    if [ ! -d "$p" ]; then c_ylw "  $p  (does not exist — left out)"; fi
  done

  echo "folders the podman machine shares"
  if [ "$have" = 0 ]; then
    c_ylw "  could not ask the VM — is the machine running?"
  elif [ "$MACHINE_SHARE_COUNT" -eq 0 ]; then
    info "none"
  else
    i=0
    while [ "$i" -lt "$MACHINE_SHARE_COUNT" ]; do
      t="${MACHINE_SHARES[$i]}"
      i=$((i + 1))
      need=0
      for p in ${REQ_SHARES[@]+"${REQ_SHARES[@]}"}; do
        case "$p" in "$t"|"$t"/*) need=1 ;; esac
      done
      if share_too_wide "$t"; then
        c_ylw "  $t  — exposes your home folder or the stack's own files to the VM"
      elif [ "$need" = 1 ]; then
        c_grn "  $t"
      else
        info "$t  (not needed by this stack)"
      fi
    done
  fi

  # Resources carried over from the current machine, so re-creating it changes the
  # shares and nothing else. Defaults are the README's.
  name="$MACHINE"
  # Sized like the machine it replaces — or, before there is one, like whichever podman
  # machine exists now, so a first `init` keeps the VM type and disk you already chose.
  local src="$MACHINE"
  if [ -z "$(machine_name)" ]; then
    src="$(podman machine ls --format '{{.Name}}' 2>/dev/null | sed 's/\*$//' | head -1 || true)"
  fi
  if [ -n "$src" ]; then
    res="$(podman machine inspect "$src" --format '{{.Resources.CPUs}} {{.Resources.Memory}} {{.Resources.DiskSize}}' 2>/dev/null | head -1 || true)"
  fi
  read -r cpus mem disk <<EOF || true
$res
EOF
  case "$cpus" in ''|*[!0-9]*) cpus=4;    guessed=1 ;; esac
  case "$mem"  in ''|*[!0-9]*) mem=8192;  guessed=1 ;; esac
  case "$disk" in ''|*[!0-9]*) disk=60;   guessed=1 ;; esac
  # The VM type too (applehv, libkrun): init otherwise takes the installed default.
  # `machine ls` marks the default machine with a trailing *.
  provider="$(podman machine ls --format '{{.Name}} {{.VMType}}' 2>/dev/null \
    | awk -v n="${src:-$name}" '{ sub(/\*$/, "", $1) } $1 == n { print $2; exit }' || true)"

  echo
  echo "a machine sharing only those folders (source and target must be identical):"
  printf '  %spodman machine init --rootful --cpus %s --memory %s --disk-size %s \\\n' \
    "${provider:+CONTAINERS_MACHINE_PROVIDER=$provider }" "$cpus" "$mem" "$disk"
  i=0
  while [ "$i" -lt "$REQ_SHARE_COUNT" ]; do
    p="${REQ_SHARES[$i]}"
    i=$((i + 1))
    printf '    --volume %q \\\n' "$p:$p"
  done
  printf '    %s\n' "$name"
  if [ "$guessed" = 1 ]; then
    c_ylw "  no podman machine to measure — check --cpus, --memory and --disk-size"
    c_ylw "  before running it"
  elif [ "$src" != "$MACHINE" ]; then
    info "sized like the existing machine '$src'"
  fi
  if [ -n "$(machine_name)" ]; then
    info "that replaces the machine and everything in it — follow README.md,"
    info "'Narrowing the machine's shares', which starts with a backup"
  else
    info "podman runs one VM at a time on macOS: stop any other podman machine first,"
    info "then start this one with: podman machine start $MACHINE"
  fi
}
