# shellcheck shell=bash
# Settings: every path, name, image and knob, derived from etc/amphora.local or defaulted.
# Sourced by bin/amphoractl, never run on its own.

# Where everything the stack *produces* lives: the agent's projects, the outbox,
# archived output, snapshots, logs. Defaults to the checkout, which keeps a fresh clone
# self-contained; a live install points it outside, so the checkout holds code and
# config and nothing else. Only projects/ and outbox/ inside it are ever shared with
# the machine — the folder itself stays above the mount.
RUNTIME_DIR="${AMPHORA_RUNTIME_DIR:-$STACK_DIR}"

# ---------------------------------------------------------------- settings --
# The agent sees two roots, at the same paths in dind as in its sandbox:
#   /projects        its own work, one folder per project
#   /mounts/<name>   everything else it is handed: the outbox, the vault board, and
#                    each etc/mounts entry
# Keeping them apart means no mount is nested inside another, so the inner engine never
# leaves empty mount points in the projects folder on the Mac, and a mount cannot
# collide with a project. The stack's own files (bin/, etc/, README.md) sit
# outside both and are unreachable from the sandbox.
SB_PROJECTS="/projects"
SB_MOUNTS="/mounts"
WORKSPACE_HOST="${AMPHORA_WORKSPACE:-$RUNTIME_DIR/projects}"   # -> /projects

# HERMES_WRITE_SAFE_ROOT: the file tools write under these and nowhere else. Every mount
# lives under the first two, so adding one never widens the list; --ro is enforced by
# the mount itself. /opt/data is Hermes' own state.
WRITE_SAFE_ROOT="$SB_PROJECTS:$SB_MOUNTS:/opt/data"

# Files the agent sends back over a messaging platform. Hermes hands signal-cli a path,
# and both check the file exists, so the sandbox, hermes and amphora-signal must all see
# it at the same place: writable in the sandbox, read-only in the other two. A folder of
# its own, so that signal-cli — which handles traffic from anyone who messages the
# number — can read what the agent chose to send and nothing else.
OUTBOX_HOST="${AMPHORA_OUTBOX:-$RUNTIME_DIR/outbox}"            # -> /mounts/outbox
SB_OUTBOX="$SB_MOUNTS/outbox"

# Obsidian, entirely optional. AMPHORA_VAULT is the single switch for every part of
# it — this bind, the sweep, and the scheduled sweep — so a machine or VM without the
# vault turns the whole feature off by leaving one variable unset, and behaves exactly
# like a checkout that never heard of Obsidian. Same shape as Signal.
#
# Only one folder of the vault crosses, the one holding the board:
#   <vault>/Kanban -> /mounts/kanban
# The vault itself is never mounted. The sweep (tools/obsidian-kanban/) runs on the
# Mac and reads the vault in place, so the agent has a route to the board and none to
# the notes.
#
# The board has to be a real vault document — wikilinks back to source notes resolve
# only inside the vault holding them, and Obsidian Sync is per-vault — so it cannot
# live under projects/ and has to cross separately.
#
# Must be inside a folder the podman machine shares (see `amphoractl shares`) — a
# path the VM cannot see binds empty and silent.
VAULT_ROOT="${AMPHORA_VAULT:-}"
VAULT_KANBAN="${VAULT_ROOT:+${AMPHORA_VAULT_KANBAN:-$VAULT_ROOT/Kanban}}"
SB_KANBAN="$SB_MOUNTS/kanban"
# Extra folders exposed to the agent, listed in etc/mounts (gitignored; template in
# etc/mounts.example) and managed with `amphoractl mount add|rm|ls`. Each entry crosses
# the same two hops the projects folder does:
#
#   <folder on the Mac> -> /mounts/<name>
#
# amphoractl owns both hops. The first is a bind on the dind container (start_dind); the
# second is the docker_volumes block it generates into the copy of etc/config.yaml
# that `config push` sends, so the two cannot drift. The destination is always
# /mounts/<name> — never /workspace, which Hermes owns — and `kanban` and `outbox` are
# taken.
MOUNTS_FILE="${AMPHORA_MOUNTS_FILE:-$STACK_DIR/etc/mounts}"

# Markers delimiting the generated block in etc/config.yaml. Everything outside them is
# pushed byte for byte.
MOUNT_MARK_BEGIN="# >>> amphoractl:mounts"
MOUNT_MARK_END="# <<< amphoractl:mounts"

# The podman machine Amphora runs in, and nothing else does. General container work on
# this Mac belongs on a different engine with its own VM: podman on macOS runs one VM at a
# time, and anything else that can reach this machine's engine — a `docker system prune
# --volumes` through /var/run/docker.sock, say — can delete hermes-data and the Signal
# keys. So every podman call amphoractl makes goes to this machine's rootful connection by name,
# never to whatever the default happens to be. doctor checks nothing else points here.
MACHINE="${AMPHORA_MACHINE:-amphora}"
CONNECTION="${AMPHORA_CONNECTION:-$MACHINE-root}"
export CONTAINER_CONNECTION="$CONNECTION"

NET="amphora-net"
C_HERMES="hermes"
C_DIND="amphora-dind"
C_SEARX="amphora-searxng"
VOL_DATA="hermes-data"           # /opt/data  — Hermes state, .env, sessions, memories
VOL_DIND="amphora-dind-storage"   # inner engine's image/container store
VOL_CERTS="amphora-dind-certs"    # mTLS material shared dind ⇄ hermes
VOL_SEARX="amphora-searxng-config"       # seeded from etc/searxng, rewritten by the image

# Pinned by digest, so a Hermes upgrade is a commit: promote snapshots first and rollback
# returns the pin. `amphoractl update check` prints the replacement for the pin line.
HERMES_REPO="docker.io/nousresearch/hermes-agent"
HERMES_PIN="sha256:ef0650d523ee1b5ab32c779acabc446d9936869a9932591553688a62bcf0c42f"  # v0.23.4
IMG_HERMES="${AMPHORA_HERMES_IMAGE:-$HERMES_REPO@$HERMES_PIN}"
# Toolsets that act in the Hermes container, outside the sandbox. config.yaml disables them;
# doctor checks the live copy.
TOOLSETS_OFF="computer_use browser connections catalog"
IMG_DIND="${AMPHORA_DIND_IMAGE:-docker.io/library/docker:dind}"
# The sandbox image is built locally so the macOS user's UID/GID can be baked into
# it — see etc/sandbox/Containerfile and "user mapping" below.
IMG_SANDBOX="${AMPHORA_SANDBOX_IMAGE:-amphora-sandbox:local}"
SANDBOX_BASE="${AMPHORA_SANDBOX_BASE:-docker.io/nikolaik/python-nodejs:python3.11-nodejs20}"

# User mapping: everything the agent writes into /workspace is owned by these ids,
# so files land on the Mac owned by you. Do NOT use Hermes'
# terminal.docker_run_as_host_user for this — it resolves `id -u` inside the Hermes
# container (UID 10000), not on the Mac.
HOST_UID="${AMPHORA_UID:-$(id -u)}"
HOST_GID="${AMPHORA_GID:-$(id -g)}"
IMG_SEARX="${AMPHORA_SEARXNG_IMAGE:-docker.io/searxng/searxng:latest}"

BIND_ADDR="${AMPHORA_BIND_ADDR:-127.0.0.1}"
# The dashboard is the only published port. The gateway API (8642) is deliberately
# not published; see "Gateway API" in README.md before adding it back.
PORT_DASH="9119"

# The zone cron expressions are evaluated in; the containers themselves run UTC. Passed
# to Hermes as HERMES_TIMEZONE, which it reads before config.yaml. The default is the
# host's own zone, read off /etc/localtime — a symlink into zoneinfo on macOS and Linux
# alike — so a fresh checkout is right wherever it runs; UTC if that cannot be read.
host_timezone() {
  local l
  l="$(readlink /etc/localtime 2>/dev/null || true)"
  case "$l" in
    *zoneinfo/*) printf '%s' "${l##*zoneinfo/}" ;;
    *) printf 'UTC' ;;
  esac
}
TIMEZONE="${AMPHORA_TIMEZONE:-$(host_timezone)}"

MEM_HERMES="${AMPHORA_HERMES_MEMORY:-4g}"
CPUS_HERMES="${AMPHORA_HERMES_CPUS:-2}"

# SELinux MCS level the hermes container runs at. The machine VM is enforcing, a file
# takes the level of the process that creates it, and podman does not relabel a named
# volume on mount. Left alone, podman draws a fresh random category pair on every
# recreate, so each `config push` strands everything Hermes created since the one
# before — silently: /opt/data still lists, its contents will not open. Pinning the
# pair keeps the volume readable across recreates and still separates Hermes from the
# other confined containers. The value itself is arbitrary. Changing it strands what
# was written under the old one until the volume is levelled to s0 (see doctor).
MCS_HERMES="${AMPHORA_HERMES_MCS_LEVEL:-s0:c421,c907}"

# Hermes' own state, shared read-only into dind at the same paths. Hermes creates its
# sandbox with binds whose sources are paths in *its* container — skills, the inbound
# document and media caches, attachments — and dind, not Hermes, resolves them, so
# without these every one arrives as an empty directory. Each is a subpath mount of the
# data volume. The volume root is deliberately not shared, so .env, auth.json, state.db
# and any skill-declared credential file still arrive empty. sandboxes/ is left out too:
# Hermes' rw home and workspace mounts under it stay local to dind.
#
# The idmap presents Hermes' uid as the sandbox user's. skills/ is 0700 and Hermes
# resets that on every start, so no chmod survives; the mapped mount is read-only and
# changes nothing on disk. Direction is file owner -> id seen in the container, verified
# 16 Sep 2026, and it carries through dind's own nested bind.
#
# A subpath mount pins the directory it found at creation. Anything that replaces one —
# a restore, Hermes rebuilding a tree — leaves dind on the old copy until it is
# recreated; doctor compares inodes to catch that.
HERMES_DATA_UID=10000
DATA_ROOT="/opt/data"
DATA_SHARED="skills cache/documents cache/images cache/audio cache/videos cache/screenshots cache/web cache/delegation cache/spillover cache/pruned cache/generated images attachments composer-pastes"
DATA_IDMAP="uids=$HERMES_DATA_UID-$HOST_UID-1;gids=$HERMES_DATA_UID-$HOST_GID-1"
# Also mounted at its own path in the sandbox, not only at /root/.hermes: upstream
# (#18787) tells the agent where an inbound document is by its /opt/data path.
DATA_DOCS="$DATA_ROOT/cache/documents"

# podman secret name -> env var name handed to the Hermes process
declare -a SECRET_MAP=(
  "openrouter_api_key:OPENROUTER_API_KEY"
  "hermes_dashboard_user:HERMES_DASHBOARD_BASIC_AUTH_USERNAME"
  "hermes_dashboard_pass:HERMES_DASHBOARD_BASIC_AUTH_PASSWORD"
  "hermes_dashboard_session:HERMES_DASHBOARD_BASIC_AUTH_SECRET"
)
