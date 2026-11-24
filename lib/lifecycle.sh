# shellcheck shell=bash
# Starting, stopping and configuring the stack: secrets, containers, config push, project.
# Sourced by bin/amphoractl, never run on its own.

# ----------------------------------------------------------------- secrets --
cmd_secrets() {
  need_podman
  case "${1:-set}" in
    list) podman secret ls ;;
    rm)
      local pair name
      for pair in "${SECRET_MAP[@]}"; do name="${pair%%:*}"; podman secret rm "$name" 2>/dev/null || true; done
      # Outside the map when no mailbox is configured, and it must not outlive the others.
      podman secret rm "$SECRET_EMAIL" 2>/dev/null || true
      c_grn "secrets removed" ;;
    set)
      if [ "${2:-}" = "email" ]; then email_secret_set; return 0; fi
      [ -z "${2:-}" ] || die "usage: amphoractl secrets set [email]"
      local key user pass
      read -r -s -p "OpenRouter API key (sk-or-...): " key; echo
      [ -n "$key" ] || die "empty key"
      printf '%s' "$key" | podman secret create --replace openrouter_api_key - >/dev/null
      unset key

      read -r -p "Dashboard username [admin]: " user; user="${user:-admin}"
      printf '%s' "$user" | podman secret create --replace hermes_dashboard_user - >/dev/null

      read -r -s -p "Dashboard password: " pass; echo
      [ -n "$pass" ] || die "empty password"
      printf '%s' "$pass" | podman secret create --replace hermes_dashboard_pass - >/dev/null
      unset pass

      openssl rand -hex 32 | tr -d '\n' | podman secret create --replace hermes_dashboard_session - >/dev/null
      if email_enabled; then email_secret_set; fi
      c_grn "secrets stored in podman's secret store (not on this disk, not in git)"
      info "re-run 'amphoractl up' to pick up changes" ;;
    *) die "usage: amphoractl secrets [set [email]|list|rm]" ;;
  esac
}

# ---------------------------------------------------------------- lifecycle --
ensure_infra() {
  ensure_runtime_dirs
  write_stack_pointer
  podman network exists "$NET" 2>/dev/null || podman network create "$NET" >/dev/null
  local v
  for v in "$VOL_DATA" "$VOL_DIND" "$VOL_CERTS" "$VOL_SEARX"; do
    podman volume exists "$v" 2>/dev/null || podman volume create "$v" >/dev/null
  done
  if signal_enabled; then
    signal_networks
    signal_ensure_volume
  fi
}

# A subpath has to exist when the mount is made, and on a fresh volume Hermes has not
# created them yet. Missing ones are made here, owned by Hermes. The helper runs
# without label separation, so what it creates is categoryless s0, readable at any
# level — the same as a restore produces.
ensure_data_subdirs() {
  podman run --rm --entrypoint sh \
    --security-opt label=disable \
    --network none \
    -v "$VOL_DATA:/data" "$IMG_DIND" \
    -c 'for p in "$@"; do
          [ -d "/data/$p" ] && continue
          mkdir -p "/data/$p" || exit 1
          chown '"$HERMES_DATA_UID:$HERMES_DATA_UID"' "/data/$p" "$(dirname "/data/$p")"
        done' _ $DATA_SHARED >/dev/null
}

# Fills DATA_MOUNT_ARGS with one read-only, idmapped subpath mount per DATA_SHARED entry.
build_data_mounts() {
  DATA_MOUNT_ARGS=()
  local p
  for p in $DATA_SHARED; do
    DATA_MOUNT_ARGS+=(--mount "type=volume,src=$VOL_DATA,dst=$DATA_ROOT/$p,subpath=$p,ro,idmap=$DATA_IDMAP")
  done
}

start_dind() {
  # Checked before the old container goes, so a bad path cannot leave dind down.
  bind_source_check "$WORKSPACE_HOST" "the projects folder" || return 1
  bind_source_check "$OUTBOX_HOST" "the outbox (AMPHORA_OUTBOX)" || return 1

  # An array, not an unquoted ${VAR:+...}: a vault path with a space in it would
  # otherwise word-split into two broken arguments. bash 3.2 has indexed arrays.
  # Empty array + "${a[@]}" under `set -u` is why the ${a[@]+"${a[@]}"} form is used.
  local -a vault_bind=()
  if vault_kanban_enabled; then
    vault_kanban_check || return 1
    vault_bind=(-v "$VAULT_KANBAN:$SB_KANBAN")
  fi

  podman rm -f "$C_DIND" >/dev/null 2>&1 || true

  # Extra folders from etc/mounts, on the same footing. This is the first of the two
  # hops; the second is the docker_volumes block push_config generates, and the two are
  # built from the same list so they cannot disagree.
  load_mounts
  build_mount_binds

  ensure_data_subdirs || { c_red "  could not create Hermes' shared state folders in $VOL_DATA"; return 1; }
  build_data_mounts

  podman run -d \
    --name "$C_DIND" \
    --label "$OWNER_LABEL=$STACK_DIR" \
    --network "$NET" --network-alias docker \
    --restart unless-stopped \
    --privileged \
    -e DOCKER_TLS_CERTDIR=/certs \
    -v "$VOL_CERTS:/certs" \
    -v "$VOL_DIND:/var/lib/docker" \
    -v "$WORKSPACE_HOST:$SB_PROJECTS" \
    -v "$OUTBOX_HOST:$SB_OUTBOX" \
    ${vault_bind[@]+"${vault_bind[@]}"} \
    ${MOUNT_BIND_ARGS[@]+"${MOUNT_BIND_ARGS[@]}"} \
    "${DATA_MOUNT_ARGS[@]}" \
    "$IMG_DIND" --storage-driver overlay2 >/dev/null
  info "waiting for the inner engine to generate its TLS material"
  local i
  for i in $(seq 1 90); do
    if podman exec "$C_DIND" test -f /certs/client/cert.pem >/dev/null 2>&1 \
       && podman exec "$C_DIND" docker info >/dev/null 2>&1; then
      c_grn "  inner engine up"
      return 0
    fi
    sleep 2
  done
  c_red "  inner engine did not come up — podman logs $C_DIND"
  return 1
}

# The only check that matters: hermes -> dind over mTLS. `docker info` run *inside*
# dind uses its local unix socket and proves nothing about this path.
check_engine_link() {
  local out i
  for i in $(seq 1 10); do
    if out="$(podman exec "$C_HERMES" docker info 2>&1)"; then
      return 0
    fi
    sleep 2
  done
  c_red "  hermes cannot talk to the inner engine"
  printf '%s\n' "$out" | tail -6 | sed 's/^/    /' >&2
  return 1
}

build_sandbox() {  local f log
  f="$STACK_DIR/etc/sandbox/Containerfile"
  [ -f "$f" ] || die "etc/sandbox/Containerfile missing"
  log="/tmp/amphoractl-sandbox-build.$$.log"
  info "building $IMG_SANDBOX for uid $HOST_UID:$HOST_GID"
  # Dockerfile on stdin: no build context is needed and none is sent.
  if ! podman exec -i "$C_DIND" docker build \
       --build-arg "HOST_UID=$HOST_UID" \
       --build-arg "HOST_GID=$HOST_GID" \
       --build-arg "BASE=$SANDBOX_BASE" \
       -t "$IMG_SANDBOX" - < "$f" > "$log" 2>&1; then
    tail -40 "$log" >&2
    rm -f "$log"
    die "sandbox image build failed (full log was $log)"
  fi
  rm -f "$log"
  c_grn "  $IMG_SANDBOX built"
}

# SearXNG's entrypoint rewrites settings.yml in place to substitute the secret, so
# the file cannot be bind-mounted read-only from this repo. Copy it into the volume
# on every `up` instead, keeping etc/searxng/settings.yml as the source of truth.
# Fed on stdin, not through a bind: etc/ is deliberately not a machine share.
seed_searxng_config() {
  local src="$STACK_DIR/etc/searxng/settings.yml"
  [ -f "$src" ] || die "etc/searxng/settings.yml missing"
  podman run --rm -i --entrypoint sh \
    -v "$VOL_SEARX:/dest" \
    "$IMG_DIND" -c 'cat > /dest/settings.yml' < "$src" >/dev/null
}

start_searxng() {
  # Auto-provisioned, never prompted: it only signs this private instance's
  # preferences, and nothing outside amphora-net can reach the service.
  if ! secret_exists searxng_secret; then
    openssl rand -hex 32 | tr -d '\n' | podman secret create searxng_secret - >/dev/null
  fi
  seed_searxng_config
  podman rm -f "$C_SEARX" >/dev/null 2>&1 || true
  podman run -d \
    --name "$C_SEARX" \
    --label "$OWNER_LABEL=$STACK_DIR" \
    --network "$NET" --network-alias searxng \
    --restart unless-stopped \
    --memory 1g \
    -v "$VOL_SEARX:/etc/searxng" \
    --tmpfs /var/cache/searxng:rw,size=128m \
    --secret searxng_secret,type=env,target=SEARXNG_SECRET \
    "$IMG_SEARX" >/dev/null
  local i
  for i in $(seq 1 45); do
    # python3 rather than curl: the Hermes image guarantees Python, not curl.
    if podman exec "$C_HERMES" python3 -c \
         "import urllib.request as u; u.urlopen('http://searxng:8080/search?q=test&format=json', timeout=5).read(1)" \
         >/dev/null 2>&1; then
      c_grn "  searxng answering JSON"
      return 0
    fi
    sleep 2
  done
  c_ylw "  searxng not answering JSON yet — check: podman logs $C_SEARX"
  return 0
}

start_hermes() {
  # Checked before the old container goes, so a typo cannot leave Hermes down.
  mcs_level_ok "$MCS_HERMES" \
    || die "AMPHORA_HERMES_MCS_LEVEL '$MCS_HERMES' is not s0:cN,cM with N < M <= 1023"
  case "$TIMEZONE" in
    ''|*[!A-Za-z0-9_+/-]*) die "AMPHORA_TIMEZONE '$TIMEZONE' is not an IANA zone name such as America/New_York" ;;
  esac
  bind_source_check "$OUTBOX_HOST" "the outbox (AMPHORA_OUTBOX)" || return 1
  email_check || die "fix the email settings in etc/amphora.local (see etc/amphora.local.example)"
  signal_check || die "fix the Signal settings in etc/amphora.local (see etc/amphora.local.example)"
  podman rm -f "$C_HERMES" >/dev/null 2>&1 || true
  # shellcheck disable=SC2046
  podman run -d \
    --name "$C_HERMES" \
    --label "$OWNER_LABEL=$STACK_DIR" \
    --network "$NET" \
    --restart unless-stopped \
    --security-opt "label=level:$MCS_HERMES" \
    --memory "$MEM_HERMES" --cpus "$CPUS_HERMES" \
    -p "$BIND_ADDR:$PORT_DASH:9119" \
    -v "$VOL_DATA:/opt/data" \
    -v "$VOL_CERTS:/certs:ro" \
    -v "$OUTBOX_HOST:$SB_OUTBOX:ro" \
    --tmpfs "$SB_PROJECTS:ro,size=64k,mode=0555" \
    -e DOCKER_HOST="tcp://docker:2376" \
    -e DOCKER_TLS_VERIFY=1 \
    -e DOCKER_CERT_PATH=/certs/client \
    -e HERMES_DASHBOARD=1 \
    -e HERMES_WRITE_SAFE_ROOT="$WRITE_SAFE_ROOT" \
    -e HERMES_TIMEZONE="$TIMEZONE" \
    -e SEARXNG_URL="http://searxng:8080" \
    $(secret_args) \
    $(signal_args) \
    $(email_args) \
    "$IMG_HERMES" gateway run >/dev/null
}

# The sandbox half of every mount. This list has to agree with the binds on the dind
# container, so it is generated from the same source rather than maintained by hand in
# two files — the failure mode of a disagreement is an empty directory and no error.
config_volume_block() {
  build_exposures
  printf '  docker_volumes:\n'
  local i=0
  while [ "$i" -lt "${#EX_SB[@]}" ]; do
    if [ "${EX_MODE[$i]}" = "ro" ]; then
      printf '    - "%s:%s:ro"\n' "${EX_DIND[$i]}" "${EX_SB[$i]}"
    else
      printf '    - "%s:%s"\n' "${EX_DIND[$i]}" "${EX_SB[$i]}"
    fi
    i=$((i + 1))
  done
  printf '    - "%s:%s:ro"\n' "$DATA_DOCS" "$DATA_DOCS"
}

# etc/config.yaml is copied verbatim except between the mount markers. Without them —
# an older config.yaml, say — the file is pushed unchanged and said so, rather than
# quietly leaving the agent with a volume list nothing else on this stack agrees with.
render_config() {
  local dest="$1" src="$STACK_DIR/etc/config.yaml" block
  if ! grep -qF "$MOUNT_MARK_BEGIN" "$src" || ! grep -qF "$MOUNT_MARK_END" "$src"; then
    c_ylw "  no '$MOUNT_MARK_BEGIN' block in etc/config.yaml — pushing it unchanged"
    info "  the agent will get whatever docker_volumes that file lists, which is not"
    info "  necessarily what 'amphoractl mount ls' shows"
    cp "$src" "$dest"
    return 0
  fi
  block="$(config_volume_block)"
  # Done in bash rather than awk. macOS ships the one-true-awk, which rejects a newline
  # inside a -v assignment outright ("awk: newline in string"), so a generated block
  # cannot be passed to it that way at all — and gawk accepts it, so a Linux test says
  # nothing about this. Same class as the bash 3.2 rule above cmd_signal.
  local line skip=0
  : > "$dest"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"$MOUNT_MARK_BEGIN"*)
        printf '%s\n' "$line" >> "$dest"
        printf '%s\n' "$block" >> "$dest"
        skip=1
        continue ;;
      *"$MOUNT_MARK_END"*)
        skip=0 ;;
    esac
    if [ "$skip" -eq 0 ]; then printf '%s\n' "$line" >> "$dest"; fi
  done < "$src"
}

push_config() {
  [ -f "$STACK_DIR/etc/config.yaml" ] || { c_ylw "  etc/config.yaml missing — skipped"; return 0; }
  local i staged
  staged="${TMPDIR:-/tmp}/amphoractl-config.$$.yaml"
  render_config "$staged"
  for i in $(seq 1 60); do
    podman exec "$C_HERMES" test -f /opt/data/config.yaml >/dev/null 2>&1 && break
    sleep 1
  done
  podman cp "$staged" "$C_HERMES:/opt/data/config.yaml"
  rm -f "$staged"
  podman exec --user root "$C_HERMES" chown 10000:10000 /opt/data/config.yaml
  c_grn "  config.yaml pushed into the data volume"
}

# Before anything is removed: podman run would pull a missing image itself, but only after
# the old container has gone, and a failed pull would then leave the stack down.
ensure_hermes_image() {
  podman image exists "$IMG_HERMES" && return 0
  echo "pulling $IMG_HERMES"
  podman pull "$IMG_HERMES" >/dev/null || die "could not pull $IMG_HERMES — nothing was changed"
}

cmd_up() {
  local feeds_ok=1
  need_podman
  require_secrets
  signal_check || die "fix the Signal settings in etc/amphora.local"
  ensure_hermes_image
  ensure_infra
  echo "starting inner container engine"
  start_dind
  echo "building the agent sandbox image"
  build_sandbox
  # The sandbox container lives in the dind volume and survives down/up, so a
  # rebuilt image would be ignored until the stale container is removed.
  cmd_reset_sandbox
  if signal_enabled; then
    if signal_registered; then
      echo "building the Signal relay and starting signal-cli"
      build_signal_relay
      start_signal
    else
      c_ylw "signal: $SIGNAL_ACCOUNT is not registered yet — amphoractl signal register '<captcha>'"
    fi
  else
    # Switched off since: nothing else would remove it, and it can still send as the bot.
    remove_signal
  fi
  if email_enabled; then
    email_check || die "fix the email settings in etc/amphora.local (see etc/amphora.local.example)"
    echo "building and starting the mail relay"
    build_mail
  fi
  start_mail
  # The fetcher is optional and nothing else depends on it, so its failures cost the
  # digest and never the agent: a list that does not parse once stopped `up` here, with
  # Hermes and SearXNG still to start. The subshell is what contains the `die`s; a
  # fetcher that was already running is left as it was.
  if feeds_enabled; then echo "building and starting the feeds fetcher"; fi
  if ! ( if feeds_enabled; then build_feeds; fi && start_feeds ); then
    feeds_ok=0
    c_ylw "  feeds not started — carrying on without it; fix the above, then: amphoractl feeds push"
  fi
  echo "starting hermes"
  start_hermes
  push_config
  echo "starting searxng"
  start_searxng
  podman restart "$C_HERMES" >/dev/null
  echo "checking the hermes -> engine link"
  if check_engine_link; then c_grn "  ok"; else c_ylw "  engine link is down — see the error above"; fi
  c_grn "up"
  info "dashboard  http://$BIND_ADDR:$PORT_DASH"
  info "chat       amphoractl chat"
  if signal_enabled; then info "signal     amphoractl signal status"; fi
  if email_enabled; then info "email      $EMAIL_ACCOUNT — amphoractl doctor"; fi
  if [ "$feeds_ok" = 0 ]; then c_ylw "feeds      NOT started — see the error above, then: amphoractl feeds push"; fi
}

cmd_down() {
  need_podman
  podman rm -f "$C_HERMES" >/dev/null 2>&1 || true
  podman rm -f "$C_SEARX"  >/dev/null 2>&1 || true
  remove_signal
  podman rm -f "$C_MAIL"   >/dev/null 2>&1 || true
  podman rm -f "$C_FEEDS"  >/dev/null 2>&1 || true
  podman rm -f "$C_DIND"   >/dev/null 2>&1 || true
  c_grn "down (volumes and secrets kept)"
}

# Recreate rather than restart: environment variables are fixed when a container is
# created, so `podman restart` would keep stale ones. Callers have run owner_check.
cmd_config_push() {
  require_secrets
  ensure_hermes_image
  ensure_infra
  push_config
  email_check || die "fix the email settings in etc/amphora.local"
  signal_check || die "fix the Signal settings in etc/amphora.local"
  start_mail
  refresh_signal
  start_hermes
  if check_engine_link; then c_grn "recreated"; else c_ylw "recreated, engine link down"; fi
}

cmd_status() {
  need_podman
  podman ps --filter "name=^${C_HERMES}$" --filter "name=^${C_DIND}$" --filter "name=^${C_SEARX}$" --filter "name=^${C_SIGNAL}$" --filter "name=^${C_SIGRELAY}$" --filter "name=^${C_MAIL}$" --filter "name=^${C_FEEDS}$" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  if running "$C_DIND"; then
    echo
    echo "sandbox containers inside the inner engine:"
    podman exec "$C_DIND" docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' || true
  fi
}

cmd_logs() {
  need_podman
  case "${1:-hermes}" in
    hermes)  podman logs -f "$C_HERMES" ;;
    dind)    podman logs -f "$C_DIND" ;;
    searxng) podman logs -f "$C_SEARX" ;;
    signal)  signal_logs ;;
    signal-relay) podman logs -f "$C_SIGRELAY" ;;
    mail)    podman logs -f "$C_MAIL" ;;
    feeds)   podman logs -f "$C_FEEDS" ;;
    agent)   podman exec -it "$C_HERMES" hermes logs --follow ;;
    *) die "usage: amphoractl logs [hermes|dind|searxng|signal|signal-relay|mail|feeds|agent]" ;;
  esac
}

# Hermes is pinned (HERMES_PIN), so this moves only the images that follow a tag.
cmd_update() {
  case "${1:-}" in
    check) cmd_update_check; return ;;
    '') ;;
    *) die "usage: amphoractl update [check]" ;;
  esac
  need_podman
  podman pull "$IMG_DIND"
  podman pull "$IMG_SEARX"
  cmd_backup run
  cmd_up
  info "Hermes itself is pinned — amphoractl update check"
}

# A throwaway container with no network and no volumes: it cannot touch the live state.
hermes_image_version() {
  local out
  out="$(podman run --rm --network none --entrypoint /opt/hermes/bin/hermes "$1" --version 2>/dev/null)" || out=""
  out="$(printf '%s\n' "$out" | sed -n 's/^Hermes Agent *//p' | sed -n 1p)"
  printf '%s' "${out:-version unknown}"
}

# Downloads the stable release and reports it. The running container is not touched.
cmd_update_check() {
  local ref="$HERMES_REPO:stable" new newid runid="" pinid="" ver
  need_podman
  echo "pulling $ref"
  podman pull "$ref" >/dev/null || die "could not pull $ref"
  newid="$(podman image inspect "$ref" --format '{{.Id}}')"
  # Not `image inspect`: its digest is this architecture's; the list's is the one Hub shows.
  new="$(podman image ls --digests --filter "reference=$ref" --format '{{.Digest}}' | sed -n 1p)"
  case "$new" in sha256:*) ;; *) die "could not read the digest of $ref" ;; esac
  runid="$(podman inspect "$C_HERMES" --format '{{.Image}}' 2>/dev/null || true)"
  pinid="$(podman image inspect "$IMG_HERMES" --format '{{.Id}}' 2>/dev/null || true)"
  ver="$(hermes_image_version "$ref")"
  if [ -n "$runid" ]; then info "running  $(hermes_image_version "$runid")"; else info "running  no hermes container"; fi
  info "stable   $ver"
  if [ -n "${AMPHORA_HERMES_IMAGE:-}" ]; then
    c_ylw "  AMPHORA_HERMES_IMAGE is set and overrides the pin: $AMPHORA_HERMES_IMAGE"
  fi
  if [ "$newid" = "$pinid" ]; then
    if [ "$newid" = "$runid" ]; then c_grn "up to date"; else c_ylw "configured but not running — amphoractl up"; fi
    return 0
  fi
  c_ylw "stable differs from the configured image; read the notes before taking it:"
  info "https://github.com/NousResearch/hermes-agent/releases"
  echo "to take it, replace this line in lib/settings.sh on dev, then promote and up:"
  printf 'HERMES_PIN="%s"  # %s\n' "$new" "${ver%% *}"
}

cmd_reset_sandbox() {
  need_podman
  podman exec "$C_DIND" sh -c \
    'ids=$(docker ps -aq --filter label=hermes-task-id); [ -n "$ids" ] && docker rm -f $ids' \
    >/dev/null 2>&1 || true
  c_grn "agent sandbox containers removed — the next tool call creates a fresh one"
}

cmd_nuke() {
  need_podman
  read -r -p "Delete containers, volumes, network AND secrets? All Hermes state is lost. [y/N] " a
  [ "$a" = "y" ] || { echo "aborted"; return 0; }
  cmd_down
  podman volume rm -f "$VOL_DATA" "$VOL_DIND" "$VOL_CERTS" "$VOL_SEARX" "$VOL_FEEDS" >/dev/null 2>&1 || true
  # Kept out of the sweep above on purpose: this one cannot be rebuilt by running up again.
  if podman volume exists "$VOL_SIGNAL" 2>/dev/null; then
    c_ylw "$VOL_SIGNAL holds the Signal account's identity keys."
    info "Deleting it does NOT deregister the number at Signal — a later register will"
    info "need --reregister, or 'amphoractl signal reset server' first."
    read -r -p "Delete it as well? [y/N] " sa
    if [ "$sa" = "y" ]; then podman volume rm -f "$VOL_SIGNAL" >/dev/null 2>&1 || true; fi
  fi
  podman network rm -f "$NET_SIGNAL" >/dev/null 2>&1 || true
  podman network rm -f "$NET_SIGNALD" >/dev/null 2>&1 || true
  podman network rm -f "$NET_MAIL" >/dev/null 2>&1 || true
  podman network rm -f "$NET_FEEDS" >/dev/null 2>&1 || true
  podman secret rm searxng_secret >/dev/null 2>&1 || true
  podman network rm -f "$NET" >/dev/null 2>&1 || true
  cmd_secrets rm
  c_grn "nuked"
}

cmd_project() {
  local action name
  action="${1:-ls}"
  case "$action" in
    ls)
      if [ -n "$(ls -A "$WORKSPACE_HOST" 2>/dev/null)" ]; then
        ls -1 "$WORKSPACE_HOST"
      else
        info "no projects yet — amphoractl project new <name>"
      fi ;;
    new)
      shift; name="${1:-}"
      [ -n "$name" ] || die "usage: amphoractl project new <name>"
      case "$name" in
        */*|.*) die "project name must be a plain folder name" ;;
      esac
      if [ -d "$WORKSPACE_HOST/$name" ]; then die "$name already exists"; fi
      mkdir -p "$WORKSPACE_HOST/$name"
      c_grn "created projects/$name  ->  /projects/$name in the sandbox" ;;
    *) die "usage: amphoractl project [ls|new <name>]" ;;
  esac
}
