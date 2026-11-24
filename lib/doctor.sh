# shellcheck shell=bash
# `doctor`.
# Sourced by bin/amphoractl, never run on its own.

# ------------------------------------------------------------------ doctor --
# Keys that must not be in /opt/data/.env, because Hermes lets that file override the
# environment amphoractl gives it. API_SERVER_KEY is upstream's own and harmless alone.
ENV_OWNED='(EMAIL|SIGNAL|HERMES|DOCKER|TERMINAL_DOCKER)_[A-Z_]+|[A-Z_]*ALLOW_ALL[A-Z_]*|[A-Z_]+_ALLOWED_USERS|TERMINAL_ENV|SEARXNG_URL|OPENROUTER_API_KEY|API_SERVER_HOST|API_SERVER_ENABLED'

cmd_doctor() {
  have_podman
  local ok=0
  echo "podman"
  info "$(podman --version)"

  # launchd runs this checkout's scripts every night, so whatever it has checked out is
  # what is live. That should be main, committed.
  echo "checkout"
  info "code     $STACK_DIR"
  info "runtime  $RUNTIME_DIR"
  local owner branch
  owner="$(stack_owner)"
  if [ -z "$owner" ]; then
    info "no running container carries an owner — the next 'up' from a checkout takes it"
  elif [ "$owner" = "$STACK_DIR" ]; then
    c_grn "  owns the running stack"
    if command -v git >/dev/null 2>&1; then
      branch="$(git -C "$STACK_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
      if [ -n "$branch" ] && [ "$branch" != "main" ]; then
        c_ylw "  on branch '$branch' — the live install should run main"
      fi
      if [ -n "$(git -C "$STACK_DIR" status --porcelain --untracked-files=no 2>/dev/null || true)" ]; then
        c_ylw "  uncommitted changes — what runs is not what is recorded"
      fi
    fi
  else
    c_ylw "  the running stack belongs to $owner — read-only here"
  fi

  local state rootful sbu vmmem clist active
  echo "podman machine"
  if [ -z "$(machine_name)" ]; then
    c_red "  no machine '$MACHINE' — amphoractl shares prints the command that creates it"
    return 1
  fi
  state="$(machine_field '{{.State}}')"
  rootful="$(machine_field '{{.Rootful}}')"
  if [ "$state" = "running" ]; then
    c_grn "  $MACHINE running"
  else
    # One VM at a time: a general-purpose podman machine started since is the usual cause.
    active="$(podman machine ls --format '{{.Name}} {{.Running}}' 2>/dev/null \
      | awk '$2 == "true" { sub(/\*$/, "", $1); print $1 }' | head -1 || true)"
    c_red "  $MACHINE not running — podman machine start $MACHINE"
    if [ -n "$active" ]; then
      info "podman runs one VM at a time, and '$active' is running — stop it first"
    fi
    ok=1
  fi
  if ! connection_exists; then
    c_red "  no connection '$CONNECTION' — every command here goes through it"
    info "a rootful machine's connection is <machine>-root; set AMPHORA_CONNECTION if yours differs"
    return 1
  fi
  if [ "$rootful" = "true" ]; then
    c_grn "  rootful (required for the privileged inner engine)"
  else
    c_red "  rootless — the privileged dind container will not start"
    info "fix: podman machine stop $MACHINE && podman machine set --rootful $MACHINE && podman machine start $MACHINE"
    ok=1
  fi

  # The VM's RAM is shared by hermes (4g limit), searxng, dind and the sandbox.
  # A default 2 GB machine cannot honour that and will OOM under a real build.
  vmmem="$(machine_field '{{.Resources.Memory}}')"
  case "$vmmem" in
    ''|*[!0-9]*) c_ylw "  could not read machine memory" ;;
    *)
      if [ "$vmmem" -ge 6144 ]; then
        c_grn "  ${vmmem} MB RAM"
      else
        c_red "  only ${vmmem} MB RAM — hermes alone is limited to $MEM_HERMES"
        info "fix: podman machine stop $MACHINE && podman machine set --memory 8192 --cpus 4 $MACHINE && podman machine start $MACHINE"
        ok=1
      fi ;;
  esac

  # Nothing but amphoractl should reach this engine. /var/run/docker.sock is what every
  # `docker` command and most tools use, and podman-mac-helper points it at whichever
  # podman machine is running — which, one VM at a time, is this one. A prune there
  # deletes hermes-data and the Signal keys without a prompt.
  echo "general container use"
  local dsock dhost pdef
  dsock="$(readlink /var/run/docker.sock 2>/dev/null || true)"
  case "$dsock" in
    */containers/podman/machine/*)
      c_red "  /var/run/docker.sock leads to podman — every docker command reaches Amphora"
      info "fix: sudo $(dirname "$(command -v podman)")/podman-mac-helper uninstall"
      info "then give general work its own engine (OrbStack, Colima, Docker Desktop)"
      ok=1 ;;
    '') info "no /var/run/docker.sock symlink" ;;
    *)  c_grn "  /var/run/docker.sock -> $dsock (not Amphora)" ;;
  esac
  dhost="${DOCKER_HOST:-}"
  case "$dhost" in
    *podman*|*"$MACHINE"*)
      c_red "  DOCKER_HOST=$dhost in this shell reaches podman — docker commands here hit Amphora"
      ok=1 ;;
  esac
  # Podman always has a default while it has any connection, so with no other machine
  # the default is necessarily one of ours. That is the intended setup, and a warning
  # that can never clear only teaches skipping warnings: it warns only when another
  # connection exists to move the default to.
  local pconns pother
  pconns="$(podman system connection ls --format '{{.Name}} {{.Default}}' 2>/dev/null || true)"
  pdef="$(printf '%s\n' "$pconns" | awk '$2 == "true" { print $1 }' | head -1)"
  pother="$(printf '%s\n' "$pconns" \
    | awk -v m="$MACHINE" 'NF && $1 != m && index($1, m "-") != 1 { print $1 }' | head -1)"
  case "$pdef" in
    "$MACHINE"|"$MACHINE"-*)
      if [ -n "$pother" ]; then
        c_ylw "  podman's default connection is $pdef — a bare podman command acts on Amphora"
        info "fix: podman system connection default $pother"
      else
        info "podman's default is $pdef, its only machine: a bare podman command acts on Amphora"
      fi
      info "amphoractl never uses the default; keep general work off podman altogether" ;;
  esac

  # Every folder a container binds has to be inside a machine share, and anything the
  # machine shares beyond that is reachable by root in the VM. Read off the VM itself.
  echo "machine shares"
  build_required_shares
  if ! load_machine_shares; then
    c_ylw "  could not ask the VM for its mounts — check skipped"
  else
    local sh_i sh_p wide=0 unshared=0
    sh_i=0
    while [ "$sh_i" -lt "$REQ_SHARE_COUNT" ]; do
      sh_p="${REQ_SHARES[$sh_i]}"
      sh_i=$((sh_i + 1))
      if under_share "$sh_p"; then
        c_grn "  $sh_p"
      else
        c_red "  $sh_p — not shared, so it binds as an empty directory"
        unshared=1
        ok=1
      fi
    done
    sh_i=0
    while [ "$sh_i" -lt "$MACHINE_SHARE_COUNT" ]; do
      sh_p="${MACHINE_SHARES[$sh_i]}"
      sh_i=$((sh_i + 1))
      if share_too_wide "$sh_p"; then
        c_ylw "  the VM also shares $sh_p — root in the VM can read and write all of it"
        wide=1
      fi
    done
    if [ "$wide" = 1 ] || [ "$unshared" = 1 ]; then
      info "amphoractl shares — the list this stack needs, and how to re-create the machine"
    fi
  fi

  # Every directory the agent can reach, and whether each bind actually arrived. These
  # binds fail silently by construction — a source the VM cannot see, or one that does
  # not exist, gives an empty directory and no error — so check what dind and the
  # running sandbox can see rather than trusting that the flags were passed.
  echo "exposed directories"
  build_exposures
  print_exposures
  if ! running "$C_DIND"; then
    c_ylw "  dind is down, so none of these binds can be checked"
  else
    local ex_i sbid sbmounts ex_host ex_dind ex_sb ex_mode dseen hseen opts eff
    sbid="$(podman exec "$C_DIND" sh -c 'docker ps -q --filter label=hermes-task-id | head -1' 2>/dev/null | tr -d '\r' || true)"
    sbmounts=""
    if [ -n "$sbid" ]; then
      sbmounts="$(podman exec "$C_DIND" docker exec "$sbid" cat /proc/self/mounts 2>/dev/null | tr -d '\r' || true)"
    fi
    ex_i=0
    while [ "$ex_i" -lt "${#EX_SB[@]}" ]; do
      ex_host="${EX_HOST[$ex_i]}"; ex_dind="${EX_DIND[$ex_i]}"
      ex_sb="${EX_SB[$ex_i]}";     ex_mode="${EX_MODE[$ex_i]}"
      ex_i=$((ex_i + 1))
      if ! podman exec "$C_DIND" test -d "$ex_dind" >/dev/null 2>&1; then
        c_red "  $ex_sb — nothing at $ex_dind inside dind: the bind was never made"
        info "  binds are fixed when dind is created — amphoractl up"
        ok=1
        continue
      fi
      dseen="$(podman exec "$C_DIND" sh -c "ls -A '$ex_dind' 2>/dev/null | wc -l" 2>/dev/null | tr -d ' \r' || true)"
      hseen="$(ls -A "$ex_host" 2>/dev/null | wc -l | tr -d ' ' || true)"
      if [ "${dseen:-0}" -eq 0 ] 2>/dev/null && [ "${hseen:-0}" -gt 0 ] 2>/dev/null; then
        c_red "  $ex_sb — empty inside dind while $ex_host is not: the bind resolved to nothing"
        info "  the source must exist, must be inside a machine share, and dind must"
        info "  have been recreated since it was configured — amphoractl up"
        ok=1
        continue
      fi
      # The sandbox side is the half config.yaml controls, and the only place a declared
      # read-only mount is actually enforced. Read it off the running sandbox rather than
      # assuming the entry took.
      if [ -n "$sbmounts" ]; then
        opts="$(printf '%s\n' "$sbmounts" | awk -v want="$ex_sb" '$2 == want { print $4 }' | tail -1 || true)"
        if [ -z "$opts" ]; then
          c_red "  $ex_sb — dind has it, the running sandbox does not"
          info "  the sandbox predates the mount, or the config never reached Hermes:"
          info "  amphoractl config push && amphoractl reset-sandbox"
          ok=1
          continue
        fi
        case ",$opts," in *,ro,*) eff="ro" ;; *) eff="rw" ;; esac
        if [ "$eff" != "$ex_mode" ]; then
          c_red "  $ex_sb — declared $ex_mode, mounted $eff in the sandbox"
          ok=1
          continue
        fi
        c_grn "  $ex_sb — $dseen entries, $eff in the sandbox"
      else
        c_grn "  $ex_sb — $dseen entries visible to the inner engine"
      fi
    done
    if [ -z "$sbmounts" ]; then
      info "no agent sandbox running, so the sandbox half is unverified — ask the agent"
      info "to run a command, then re-run doctor to confirm each mount and its ro/rw"
    fi
  fi

  # The agent's housekeeping, as a notice rather than a failure: none of it breaks the
  # stack. /projects/AGENTS.md asks for one folder per project, each with an AGENTS.md,
  # and nothing loose at the top; this reports where that has slipped. Hidden entries
  # are left alone.
  echo "projects folder"
  if [ ! -d "$WORKSPACE_HOST" ]; then
    info "$WORKSPACE_HOST does not exist yet"
  else
    local pj_e pj_n pj_loose="" pj_bare=""
    for pj_e in "$WORKSPACE_HOST"/*; do
      [ -e "$pj_e" ] || continue
      pj_n="${pj_e##*/}"
      if [ -d "$pj_e" ] && [ "$pj_n" != "__pycache__" ]; then
        [ -f "$pj_e/AGENTS.md" ] || pj_bare="$pj_bare $pj_n"
      elif [ "$pj_n" != "AGENTS.md" ]; then
        pj_loose="$pj_loose $pj_n"
      fi
    done
    if [ ! -f "$WORKSPACE_HOST/AGENTS.md" ]; then
      c_ylw "  no AGENTS.md at the top — sessions starting there get no workspace rules"
    fi
    if [ -n "$pj_loose" ]; then
      c_ylw "  loose at the top:$pj_loose"
    fi
    if [ -n "$pj_bare" ]; then
      c_ylw "  folders without an AGENTS.md:$pj_bare"
    fi
    if [ -n "$pj_loose$pj_bare" ]; then
      info "ask the agent to file these into projects — doctor does not move them"
    else
      c_grn "  one folder per project, nothing loose"
    fi
  fi

  # Hermes' own state as the sandbox receives it. Three ways this fails silently: dind
  # predates the mounts or holds a replaced directory (both show as an inode that does
  # not match Hermes'), Hermes asks for a path nobody shared (it arrives empty), or the
  # idmap did not take (the sandbox user is refused).
  echo "hermes state in the sandbox"
  if ! running "$C_DIND" || ! running "$C_HERMES"; then
    c_ylw "  needs both hermes and dind running"
  else
    local dp hino dino dbad=0 sbm src dst covered downer
    # The idmap maps one fixed uid. If a Hermes release changes the uid its image runs
    # as, the mapping silently stops matching and the sandbox is refused again.
    downer="$(podman exec "$C_HERMES" stat -c %u "$DATA_ROOT" 2>/dev/null | tr -d '\r' || true)"
    if [ -n "$downer" ] && [ "$downer" != "$HERMES_DATA_UID" ]; then
      c_red "  $DATA_ROOT is owned by uid $downer; the idmap assumes $HERMES_DATA_UID"
      info "  set HERMES_DATA_UID in lib/settings.sh to match, then amphoractl up"
      ok=1
    fi
    for dp in $DATA_SHARED; do
      hino="$(podman exec "$C_HERMES" stat -c %i "$DATA_ROOT/$dp" 2>/dev/null | tr -d '\r' || true)"
      dino="$(podman exec "$C_DIND" stat -c %i "$DATA_ROOT/$dp" 2>/dev/null | tr -d '\r' || true)"
      if [ -z "$dino" ]; then
        c_red "  $DATA_ROOT/$dp — not mounted in dind"; dbad=1
      elif [ -n "$hino" ] && [ "$hino" != "$dino" ]; then
        c_red "  $DATA_ROOT/$dp — dind holds a replaced copy"; dbad=1
      fi
    done
    if [ "$dbad" = 1 ]; then
      info "  dind predates these mounts or a directory was replaced — amphoractl up"
      ok=1
    else
      c_grn "  $(echo $DATA_SHARED | wc -w | tr -d ' ') paths shared read-only into dind, current"
    fi
    if [ -n "$sbid" ]; then
      sbm="$(podman exec "$C_DIND" docker inspect "$sbid" \
        --format '{{range .Mounts}}{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' 2>/dev/null | tr -d '\r' || true)"
      while IFS='|' read -r src dst; do
        case "$src" in "$DATA_ROOT"/*) ;; *) continue ;; esac
        case "$src" in "$DATA_ROOT"/sandboxes/*) continue ;; esac
        covered=0
        for dp in $DATA_SHARED; do
          case "$src" in "$DATA_ROOT/$dp"|"$DATA_ROOT/$dp"/*) covered=1 ;; esac
        done
        if [ "$covered" = 0 ]; then
          c_ylw "  sandbox asks for $src — not shared, arrives empty"
          info "  expected for credential files; anything else belongs in DATA_SHARED"
          continue
        fi
        if podman exec "$C_DIND" docker exec "$sbid" sh -c \
             'if [ -d "$1" ]; then ls "$1"; else head -c1 "$1"; fi' _ "$dst" >/dev/null 2>&1; then
          c_grn "  $dst — readable by the sandbox user"
        else
          c_red "  $dst — the sandbox user cannot read it"
          info "  check the idmap (AMPHORA_UID/AMPHORA_GID) and that the image's /root is 0711"
          info "  — amphoractl build-sandbox"
          ok=1
        fi
      done <<EOF
$sbm
EOF
    fi
  fi

  echo "user mapping"
  info "host uid:gid  $HOST_UID:$HOST_GID"
  if running "$C_DIND"; then
    sbu="$(podman exec "$C_DIND" docker image inspect "$IMG_SANDBOX" --format "{{.Config.User}}" 2>/dev/null | tr -d "\r" || true)"
    if [ -z "$sbu" ]; then
      c_ylw "  sandbox image not built yet — amphoractl build-sandbox"
    elif [ "$sbu" = "$HOST_UID:$HOST_GID" ]; then
      c_grn "  sandbox image runs as $sbu — files land owned by you"
    else
      c_red "  sandbox image runs as '$sbu', expected $HOST_UID:$HOST_GID"
      info "fix: amphoractl build-sandbox"
      ok=1
    fi
  fi

  if running "$C_HERMES"; then
    echo "container env drift"
    local want got
    want="$WRITE_SAFE_ROOT"
    got="$(podman exec "$C_HERMES" printenv HERMES_WRITE_SAFE_ROOT 2>/dev/null | tr -d '\r' || true)"
    if [ "$got" = "$want" ]; then
      c_grn "  HERMES_WRITE_SAFE_ROOT=$got"
    else
      c_red "  HERMES_WRITE_SAFE_ROOT is '$got', expected '$want'"
      info "the container predates the current settings — amphoractl up"
      ok=1
    fi
    # A warning, not a failure: the host's zone moves with the Mac, and a container
    # created in another zone keeps firing cron jobs on that one until it is recreated.
    got="$(podman exec "$C_HERMES" printenv HERMES_TIMEZONE 2>/dev/null | tr -d '\r' || true)"
    if [ "$got" = "$TIMEZONE" ]; then
      c_grn "  HERMES_TIMEZONE=$got"
    else
      c_ylw "  HERMES_TIMEZONE is '${got:-<unset>}', expected '$TIMEZONE'"
      info "recreate hermes to apply it — amphoractl config push — then re-set existing"
      info "cron schedules, which keep the next run time computed in the old zone"
    fi
  fi

  # The sandbox half of the outbox is covered by the exposure check above. The other
  # half is hermes and amphora-signal, which read it at the same path to send a file.
  # Read off the containers rather than assumed from the flags.
  echo "outbox"
  local ob_c ob_mounts
  for ob_c in "$C_HERMES" "$C_SIGNAL" "$C_SIGRELAY"; do
    if [ "$ob_c" != "$C_HERMES" ] && ! signal_enabled; then continue; fi
    if ! running "$ob_c"; then continue; fi
    ob_mounts="$(podman inspect "$ob_c" --format '{{range .Mounts}}{{.Destination}}:{{.RW}} {{end}}' 2>/dev/null || true)"
    case " $ob_mounts " in
      *" $SB_OUTBOX:false "*) c_grn "  $ob_c reads $SB_OUTBOX (read-only)" ;;
      *" $SB_OUTBOX:true "*)
        c_red "  $ob_c has $SB_OUTBOX writable — it should be read-only"
        ok=1 ;;
      *)
        c_red "  $ob_c has no $SB_OUTBOX — files the agent sends will not arrive"
        info "  the container predates the outbox — amphoractl up"
        ok=1 ;;
    esac
  done

  # The board's bind is covered by the exposure check above, which is generic. What is
  # left here is the half that runs on the Mac, outside every container.
  echo "vault kanban sweep"
  if ! vault_kanban_enabled; then
    info "  not configured — nothing from the vault is mounted, and the agent has"
    info "  no $SB_KANBAN at all. Set AMPHORA_VAULT to wire a board in."
  elif ! vault_kanban_check >/dev/null 2>&1; then
    vault_kanban_check || true
    ok=1
  fi
  if vault_kanban_enabled && [ -x "$STACK_DIR/tools/obsidian-kanban/kanban-todos.sh" ]; then
    local todos_plist todos_target
    todos_plist="$HOME/Library/LaunchAgents/local.amphora.todos.plist"
    # `|| true` is load-bearing under `set -o pipefail`: with no plist, sed exits
    # non-zero and the assignment takes doctor down with it — silently, mid-report,
    # which is the one thing doctor must never do.
    todos_target="$(sed -n 's|.*<string>\(/.*kanban-todos\.sh\)</string>.*|\1|p' \
      "$todos_plist" 2>/dev/null | head -1 || true)"
    if [ -z "$todos_target" ]; then
      info "  sweep not scheduled — tools/obsidian-kanban/kanban-todos.sh schedule on"
    elif [ "$todos_target" != "$STACK_DIR/tools/obsidian-kanban/kanban-todos.sh" ]; then
      # The plist is the only thing this stack writes outside its own folder, so it is
      # the only thing a move or rename can strand. launchd fails it silently.
      c_red "  scheduled sweep points at $todos_target, not this checkout"
      info "  the project was moved or renamed — fix:"
      info "  tools/obsidian-kanban/kanban-todos.sh schedule on"
      ok=1
    elif launchctl list local.amphora.todos >/dev/null 2>&1; then
      c_grn "  sweep scheduled"
    else
      c_ylw "  sweep plist present but not loaded — kanban-todos.sh schedule on"
    fi
  fi

  # The volumes live only inside the podman machine VM. A machine reset or rebuild —
  # which a Podman Desktop upgrade can prompt for — takes them with it.
  echo "backups"
  local newest age
  newest="$(ls -1d "$BACKUP_DIR"/[0-9]* 2>/dev/null | sort | tail -1 || true)"
  if [ -z "$newest" ]; then
    c_ylw "  none — every session, memory and skill exists in one place only"
    info "fix: amphoractl backup && amphoractl backup schedule on"
  else
    # A non-numeric result means something unexpected rather than a stale backup, so
    # say so instead of doing arithmetic on it.
    age="$(file_mtime "$newest")"
    case "$age" in
      ''|*[!0-9]*) c_ylw "  newest $(basename "$newest") — could not read its age" ;;
      *)
        age=$(( ( $(date +%s) - age ) / 86400 ))
        if [ "$age" -le 7 ]; then
          c_grn "  newest $(basename "$newest") (${age}d old)"
        else
          c_ylw "  newest $(basename "$newest") is ${age} days old"
        fi ;;
    esac
  fi
  if [ -f "$LAUNCHD_PLIST" ]; then
    c_grn "  nightly schedule installed"
  else
    c_ylw "  no nightly schedule — amphoractl backup schedule on"
  fi
  # Snapshots inside any working tree git can see are a leak waiting for the next
  # `git add -A` — this checkout's, or whatever repo AMPHORA_BACKUP_DIR happens to land
  # in. This is the one backup-related finding that fails doctor outright.
  if command -v git >/dev/null 2>&1 && [ -d "$BACKUP_DIR" ]; then
    local btree
    btree="$(git -C "$BACKUP_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$btree" ]; then
      c_grn "  outside every git working tree: $BACKUP_DIR"
    elif git -C "$btree" check-ignore -q "$BACKUP_DIR" 2>/dev/null; then
      c_grn "  ignored by git ($btree)"
    else
      c_red "  NOT ignored by git in $btree — snapshots are a full copy of the agent's memory"
      info "fix: restore the 'backups/' line in .gitignore, then amphoractl backup"
      ok=1
    fi
  fi
  if [ "$RUNTIME_DIR" != "$STACK_DIR" ] \
     && git -C "$RUNTIME_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
    c_ylw "  the runtime folder $RUNTIME_DIR is inside a git working tree"
    info "it holds snapshots and agent output; keep it out of every repo"
  fi

  echo "secrets"
  local pair name
  for pair in "${SECRET_MAP[@]}"; do
    name="${pair%%:*}"
    if secret_exists "$name"; then c_grn "  $name"; else c_red "  $name  (missing)"; ok=1; fi
  done

  if signal_enabled; then
    echo "signal"
    info "account $SIGNAL_ACCOUNT"
    if signal_registered; then
      c_grn "  registered"
    else
      c_ylw "  not registered — amphoractl signal register '<captcha>'"
    fi
    if [ -n "$SIGNAL_ALLOWED" ]; then
      # Signal includes the sender's number only in sealed-sender messages, which need
      # the profile key — so in practice once you and the bot have exchanged messages.
      # Before that, and always for senders with phone-number privacy on, the adapter
      # sees an ACI UUID and matches the allowlist literally.
      case "$SIGNAL_ALLOWED" in
        *-*-*-*-*) c_grn "  allowlist has a number and a UUID" ;;
        *) c_grn "  allowlist set (numbers only)"
           info "If a sender is refused with 'Unauthorized user: <uuid>' in the hermes log,"
           info "that uuid needs adding to AMPHORA_SIGNAL_ALLOWED, then: amphoractl config push" ;;
      esac
    fi
    if ! signal_check; then
      ok=1
    elif [ -n "$SIGNAL_GROUPS" ]; then
      info "groups: $(signal_group_names) — senders still matched against the allowlist"
    fi
    if running "$C_SIGNAL" && running "$C_HERMES"; then
      if ! running "$C_SIGRELAY"; then
        c_red "  $C_SIGRELAY not running — no Signal messages either way"
        podman logs --tail 3 "$C_SIGRELAY" 2>/dev/null | sed 's/^/    /' || true
        ok=1
      elif podman exec "$C_HERMES" python3 -c \
           "import urllib.request as u; u.urlopen('$SIGNAL_URL/api/v1/check', timeout=5).read(1)" \
           >/dev/null 2>&1; then
        c_grn "  daemon reachable from hermes, through the relay"
        case "$(signal_relay_probe)" in
          ok) c_grn "  relay accepts the allowlist and refuses anyone else" ;;
          listed-refused)   c_red "  relay refuses a listed recipient — amphoractl config push"; ok=1 ;;
          stranger-allowed) c_red "  relay passed on a message to an unlisted number"; ok=1 ;;
          call-allowed)     c_red "  relay passed on a call it should refuse"; ok=1 ;;
          *) c_red "  could not test the relay"; ok=1 ;;
        esac
        local sgot
        sgot="$(podman inspect "$C_SIGRELAY" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | tr -d '\r' || true)"
        if signal_enabled && [ "$(printf '%s\n' "$sgot" | sed -n 's/^RELAY_ALLOWED=//p')" = "$SIGNAL_ALLOWED" ] \
             && [ "$(printf '%s\n' "$sgot" | sed -n 's/^RELAY_GROUPS=//p')" = "$SIGNAL_GROUPS" ]; then
          c_grn "  relay has the current lists"
        else
          c_red "  relay predates the current lists — amphoractl config push"
          ok=1
        fi
      else
        c_red "  hermes cannot reach the signal-cli daemon"
        info "the containers may predate the relay — amphoractl up"
        ok=1
      fi
    fi
    # Who is on each network, then whether the rest can get there by address anyway.
    local sn sm
    for sn in "$NET_SIGNAL" "$NET_SIGNALD"; do
      sm=" $(podman network inspect "$sn" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)"
      case "$sm" in
        *" $C_DIND "*) c_red "  $C_DIND is on $sn — the agent can reach the bot's identity"; ok=1 ;;
      esac
      if [ "$sn" = "$NET_SIGNALD" ]; then
        case "$sm" in
          *" $C_HERMES "*) c_red "  $C_HERMES is on $sn — it can go around the relay"; ok=1 ;;
        esac
      else
        case "$sm" in
          *" $C_SIGNAL "*) c_red "  $C_SIGNAL is on $sn — hermes can go around the relay; amphoractl up"; ok=1 ;;
        esac
      fi
    done
  fi

  # Membership is not reach: whether one network can address another is podman's choice.
  if running "$C_DIND" && running "$C_SEARX"; then
    echo "network isolation"
    local ip pc pp open="" control
    control="$(podman inspect "$C_SEARX" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null || true)"
    if [ -z "$control" ] || ! podman exec "$C_DIND" nc -z -w 3 "$control" 8080 </dev/null >/dev/null 2>&1; then
      c_ylw "  could not probe — $C_DIND does not reach even $C_SEARX, which it should"
    else
      for pc in "$C_SIGNAL:8080" "$C_SIGRELAY:8080" "$C_MAIL:2525"; do
        pp="${pc##*:}"; pc="${pc%%:*}"
        running "$pc" || continue
        for ip in $(podman inspect "$pc" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null); do
          if podman exec "$C_DIND" nc -z -w 2 "$ip" "$pp" </dev/null >/dev/null 2>&1; then
            open="$open $C_DIND->$pc"
          fi
          if [ "$pc" = "$C_SIGNAL" ] && running "$C_HERMES" && podman exec "$C_HERMES" python3 -c \
               "import socket; socket.create_connection(('$ip', $pp), 2)" </dev/null >/dev/null 2>&1; then
            open="$open $C_HERMES->$pc"
          fi
        done
      done
      if [ -n "$open" ]; then
        c_red "  reachable by address:$open"
        ok=1
      else
        c_grn "  the sandbox's engine reaches neither relay nor the Signal daemon"
      fi
    fi
  fi

  if email_enabled; then
    echo "email"
    info "mailbox $EMAIL_ACCOUNT"
    if ! email_check; then ok=1; fi
    if [ -n "$EMAIL_ALLOWED" ]; then info "allowed $EMAIL_ALLOWED — both directions"; fi
    if [ -n "$EMAIL_HOME" ]; then info "home    $EMAIL_HOME"; fi
    if running "$C_MAIL"; then
      c_grn "  relay running"
    else
      c_red "  $C_MAIL not running — outbound mail cannot leave"
      podman logs --tail 3 "$C_MAIL" 2>/dev/null | sed 's/^/    /' || true
      info "a refused provider login stops it at start; amphoractl logs mail"
      ok=1
    fi
    # The relay is the sending allowlist, so the agent must have no route to it but Hermes.
    if podman network inspect "$NET_MAIL" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
         | grep -q "$C_DIND"; then
      c_red "  $C_DIND is on $NET_MAIL — the sandbox could reach the relay"
      ok=1
    fi
    if running "$C_HERMES"; then
      # Read back, not assumed: environment is fixed when a container is created.
      local kv key want got drift=0 res
      while IFS= read -r kv; do
        key="${kv%%=*}"; want="${kv#*=}"
        got="$(podman exec "$C_HERMES" printenv "$key" </dev/null 2>/dev/null | tr -d '\r' || true)"
        if [ "$got" != "$want" ]; then
          c_red "  $key is '${got:-<unset>}' in the running container, expected '$want'"
          drift=1
        fi
      done <<EOF
$(email_env)
EOF
      if [ "$drift" = 0 ]; then
        c_grn "  running container has the expected settings"
      else
        info "the container predates the change — amphoractl config push"
        ok=1
      fi
      if podman exec "$C_HERMES" sh -c '[ -n "${EMAIL_PASSWORD:-}" ]' </dev/null >/dev/null 2>&1; then
        # A real login proves the password, the host and the account's IMAP switch in one
        # go. Nothing is read or marked; the value never leaves the container.
        res="$(podman exec "$C_HERMES" python3 -c '
import imaplib, os
e = os.environ
try:
    m = imaplib.IMAP4_SSL(e["EMAIL_IMAP_HOST"], int(e.get("EMAIL_IMAP_PORT") or 993), timeout=10)
except Exception as x:
    print("connect " + type(x).__name__)
else:
    try:
        m.login(e["EMAIL_ADDRESS"], e["EMAIL_PASSWORD"]); m.logout(); print("ok")
    except Exception as x:
        print("login " + type(x).__name__)
' </dev/null 2>&1 | tail -1 | tr -d '\r' || true)"
        case "$res" in
          ok)      c_grn "  IMAP login ok" ;;
          login*)  c_red "  IMAP login refused — wrong app password, or IMAP off for this account"; ok=1 ;;
          *)       c_red "  IMAP unreachable from hermes: ${res:-no output}"; ok=1 ;;
        esac
        # Ask the relay, as Hermes would, to accept one allowlisted recipient and one outsider,
        # then reset before DATA: proves the enforcement live, and sends nothing.
        res="$(podman exec "$C_HERMES" python3 -c '
import os, smtplib
e = os.environ
allowed = [a.strip() for a in e.get("EMAIL_ALLOWED_USERS", "").split(",") if a.strip()]
try:
    s = smtplib.SMTP(e["EMAIL_SMTP_HOST"], int(e["EMAIL_SMTP_PORT"]), timeout=10)
    s.login(e["EMAIL_ADDRESS"], e["EMAIL_PASSWORD"])
    s.mail(e["EMAIL_ADDRESS"])
    good = s.rcpt(allowed[0])[0] if allowed else 0
    bad = s.rcpt("doctor-probe@example.invalid")[0]
    s.rset(); s.quit()
    print(good, bad)
except Exception as x:
    print(type(x).__name__)
' </dev/null 2>&1 | tail -1 | tr -d '\r' || true)"
        case "$res" in
          "250 550") c_grn "  relay accepts the allowlist and refuses anyone else" ;;
          "250 "*)   c_red "  relay ACCEPTED a recipient outside the allowlist ($res)"; ok=1 ;;
          *)         c_red "  relay check from hermes failed: ${res:-no output}"; ok=1 ;;
        esac
      else
        c_red "  no EMAIL_PASSWORD in the running container"
        info "amphoractl secrets set email, then amphoractl config push"
        ok=1
      fi
    fi
  fi

  # Regardless of whether a mailbox is configured here: Hermes also reads /opt/data/.env,
  # which its own setup wizard writes, and an allow-all flag or a mailbox set up there is
  # a second, unmanaged configuration this script would otherwise never see.
  if running "$C_HERMES"; then
    echo "gateway access"
    local n v keys allow_all=0
    for n in GATEWAY_ALLOW_ALL_USERS EMAIL_ALLOW_ALL_USERS; do
      v="$(podman exec "$C_HERMES" printenv "$n" </dev/null 2>/dev/null | tr -d '\r' || true)"
      if [ -n "$v" ]; then
        c_red "  $n=$v in the container — allow-all on an agent with terminal access"
        allow_all=1; ok=1
      fi
    done
    # Key names only. Values from that file are never printed.
    keys="$(podman exec "$C_HERMES" sh -c \
              "grep -oE '^[[:space:]]*(export[[:space:]]+)?($ENV_OWNED)=' /opt/data/.env 2>/dev/null" \
              </dev/null 2>/dev/null \
            | sed -e 's/^[[:space:]]*//' -e 's/^export[[:space:]]*//' -e 's/=$//' \
            | sort -u | tr '\n' ' ' | sed 's/ $//' || true)"
    if ! email_enabled; then
      v="$(podman exec "$C_HERMES" printenv EMAIL_ADDRESS </dev/null 2>/dev/null | tr -d '\r' || true)"
      if [ -n "$v" ]; then
        c_ylw "  the running container still has mailbox $v, which etc/amphora.local no longer"
        info "configures — amphoractl config push to drop it"
      fi
    fi
    if [ -n "$keys" ]; then
      c_red "  /opt/data/.env sets: $keys"
      info "that file overrides what amphoractl sets, so these can replace an allowlist, the"
      info "mail relay or the sandbox itself. find out who set them, then remove those lines"
      info "(amphoractl shell, edit /opt/data/.env), then amphoractl config push"
      ok=1
    elif [ "$allow_all" = 0 ]; then
      c_grn "  no allow-all, and /opt/data/.env overrides nothing of ours"
    fi
  fi

  # Everything the agent runs should be in the sandbox. These toolsets are not, and scripts,
  # hooks, plugins and MCP servers in Hermes' own folder run beside its secrets.
  if running "$C_HERMES"; then
    echo "tools outside the sandbox"
    local live off t missing="" ext=""
    live="$(podman exec "$C_HERMES" cat /opt/data/config.yaml </dev/null 2>/dev/null | tr -d '\r' || true)"
    off="$(printf '%s\n' "$live" | awk '
      /^[^[:space:]#]/ { top = $1; inlist = 0 }
      top == "agent:" && /^[[:space:]]+disabled_toolsets:/ {
        line = $0; sub(/^[^:]*:/, "", line); gsub(/[][,"\047]/, " ", line); print line; inlist = 1; next }
      inlist && /^[[:space:]]*-/ { gsub(/["\047]/, ""); print $2; next }
      inlist && /^[[:space:]]*(#|$)/ { next }
      { inlist = 0 }' | tr '\n' ' ')"
    for t in $TOOLSETS_OFF; do
      case " $off " in *" $t "*) ;; *) missing="$missing $t" ;; esac
    done
    if [ -n "$missing" ]; then
      c_red "  not disabled:$missing — the agent can run code in the Hermes container"
      info "see agent.disabled_toolsets in etc/config.yaml, then amphoractl config push"
      ok=1
    else
      c_grn "  disabled: $TOOLSETS_OFF"
    fi
    for t in scripts hooks plugins; do
      if [ -n "$(podman exec "$C_HERMES" sh -c "ls -A /opt/data/$t 2>/dev/null | head -1" </dev/null 2>/dev/null || true)" ]; then
        ext="$ext /opt/data/$t"
      fi
    done
    if printf '%s\n' "$live" | grep -q '^mcp_servers:'; then ext="$ext mcp_servers"; fi
    if [ -n "$ext" ]; then
      c_ylw "  code that runs in the Hermes container:$ext — check that you put it there"
    else
      c_grn "  no scripts, hooks, plugins or MCP servers of its own"
    fi
  fi

  if ! feeds_doctor; then ok=1; fi

  echo "containers"
  clist="$C_DIND $C_HERMES $C_SEARX"
  if signal_enabled; then clist="$clist $C_SIGNAL $C_SIGRELAY"; fi
  if email_enabled; then clist="$clist $C_MAIL"; fi
  if feeds_enabled; then clist="$clist $C_FEEDS"; fi
  for c in $clist; do
    if running "$c"; then c_grn "  $c running"; else c_ylw "  $c not running"; fi
  done

  # A VOLUME the image declares and start_* does not name gets an anonymous volume,
  # which no recreate reattaches: whatever it holds is gone from the stack at the next
  # up, left on disk as an orphan. Seeing one means an image has grown a volume.
  local c av anon=0 orphans
  for c in $clist; do
    running "$c" || continue
    av="$(podman inspect "$c" --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{.Destination}}{{"\n"}}{{end}}{{end}}' 2>/dev/null \
            | grep -E '^[0-9a-f]{64} ' | cut -d' ' -f2 || true)"
    if [ -n "$av" ]; then
      anon=1
      c_ylw "  $c has an anonymous volume at $(printf '%s' "$av" | tr '\n' ' ')"
    fi
  done
  if [ "$anon" = 1 ]; then
    info "its contents do not survive a recreate — name a volume for it in start_*,"
    info "or --tmpfs if it is only a cache"
  fi
  orphans="$(podman volume ls -q --filter dangling=true 2>/dev/null | grep -cE '^[0-9a-f]{64}$' || true)"
  case "$orphans" in
    ''|0) ;;
    *) c_ylw "  $orphans orphaned anonymous volume(s) — left by recreates; check before removing"
       info "list: podman volume ls --filter dangling=true; never volume prune" ;;
  esac

  if running "$C_HERMES"; then
    echo "inner engine reachable from hermes"
    if check_engine_link; then c_grn "  docker info ok"; else ok=1; fi
  fi

  # A promoted pin takes effect only when Hermes is recreated, and a moving tag changes
  # Hermes without a commit. Image ids, because one image has several digests.
  if running "$C_HERMES"; then
    local hrun hpin
    echo "hermes image"
    hrun="$(podman inspect "$C_HERMES" --format '{{.Image}}' 2>/dev/null || true)"
    hpin="$(podman image inspect "$IMG_HERMES" --format '{{.Id}}' 2>/dev/null || true)"
    info "running  $(podman inspect "$C_HERMES" --format '{{.ImageDigest}}' 2>/dev/null || true)"
    if [ -n "$hrun" ] && [ "$hrun" = "$hpin" ]; then
      c_grn "  running the configured image"
    else
      c_ylw "  not the configured image ($IMG_HERMES) — amphoractl up"
    fi
    case "$IMG_HERMES" in
      *@sha256:*) ;;
      *) c_ylw "  $IMG_HERMES is a tag, not a digest — unset AMPHORA_HERMES_IMAGE to use the pin" ;;
    esac
  fi

  # SELinux MCS, two checks. A file takes the level of the process that created it,
  # so Hermes at any level other than the pinned one is writing files the next
  # recreate will not be able to read. See MCS_HERMES.
  if running "$C_HERMES"; then
    echo "hermes SELinux level"
    local plabel plevel
    plabel="$(podman inspect "$C_HERMES" --format '{{.ProcessLabel}}' 2>/dev/null | tr -d '\r' || true)"
    if [ -z "$plabel" ]; then
      c_ylw "  no process label (SELinux off in the VM?) — check skipped"
    else
      plevel="${plabel#*:*:*:}"
      if [ "$plevel" = "$MCS_HERMES" ]; then
        c_grn "  $plevel — pinned"
      else
        c_red "  running at $plevel, pinned level is $MCS_HERMES"
        info "container predates the pin or AMPHORA_HERMES_MCS_LEVEL changed since —"
        info "amphoractl config push, then level the volume (below)"
        ok=1
      fi
    fi
  fi

  # The failure is silent: Hermes lists /opt/data quite happily and cannot open what is
  # in it, so bundled skills and memories simply stop existing. Test what Hermes itself
  # can reach rather than parsing labels; podman exec enters as the image's own USER,
  # which is the identity that matters. `-readable` is access(2), which SELinux checks,
  # so it catches files. A bare find only opens directories and never reports a file.
  # Symlinks are skipped: access(2) follows them, so a link into a cache the backup
  # excludes (.local/bin/cua-driver after a restore) reads as a label fault when it is
  # only dangling. Whatever a live link points at inside /opt/data is checked in its
  # own right.
  if running "$C_HERMES"; then
    echo "data volume readable by hermes"
    local out="" denied n checked=1
    if podman exec "$C_HERMES" find /opt/data -maxdepth 0 -readable >/dev/null 2>&1; then
      out="$(podman exec "$C_HERMES" find /opt/data -mindepth 1 ! -type l ! -readable -print 2>&1 || true)"
    elif podman exec "$C_HERMES" sh -c 'command -v find >/dev/null 2>&1'; then
      c_ylw "  find has no -readable — directories only"
      out="$(podman exec "$C_HERMES" find /opt/data -mindepth 1 2>&1 >/dev/null || true)"
    else
      c_ylw "  no find in the container — check skipped"
      checked=0
    fi
    if [ "$checked" = 1 ]; then
      # Paths from -print, plus directories find could not enter. Anything else find
      # says (a file vanishing mid-walk) is not a finding.
      denied="$(printf '%s\n' "$out" | grep -e '^/' -e 'Permission denied' \
                  | sed -e "s/^find: '\(.*\)': Permission denied\$/\1/" | sort -u || true)"
      if [ -z "$denied" ]; then
        c_grn "  every path under /opt/data is readable"
      else
        n="$(printf '%s\n' "$denied" | wc -l | tr -d ' ')"
        c_red "  $n unreadable under /opt/data — Hermes cannot see its own state"
        printf '%s\n' "$denied" | sed -n '1,5s/^/    /p'
        info "almost always files created at an MCS level other than the current one."
        info "once the level check above passes, level the volume from inside the VM:"
        info "  podman machine ssh $MACHINE"
        info "  sudo chcon -R -l s0 /var/lib/containers/storage/volumes/$VOL_DATA/_data"
        info "s0 is readable at any level. levelling before the pin is in place only"
        info "lasts until the next recreate."
        ok=1
      fi
    fi
  fi
  return $ok
}
