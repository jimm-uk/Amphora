# shellcheck shell=bash
# `promote` and `rollback`: moving the live checkout between commits.
# Sourced by bin/amphoractl, never run on its own.

# ----------------------------------------------------------- promote/rollback --
# The live install runs main; work happens on dev, in a worktree of its own that cannot
# touch the stack (owner_check). Promoting is a fast-forward of main to dev, with a
# snapshot first and a line in the deploy log so it can be walked back. Neither command
# restarts anything: they say which of up / config push / build-sandbox the change
# needs, and you run it — a deploy you did not watch is one you cannot vouch for.
DEPLOY_LOG="$RUNTIME_DIR/logs/deployed"

git_here() { git -C "$STACK_DIR" "$@"; }

deploy_preflight() {
  command -v git >/dev/null 2>&1 || die "git not found"
  git_here rev-parse --git-dir >/dev/null 2>&1 || die "$STACK_DIR is not a git checkout"
  [ "$(git_here rev-parse --abbrev-ref HEAD)" = "main" ] \
    || die "promote and rollback run in the live install, which is on main"
  [ -z "$(git_here status --porcelain --untracked-files=no)" ] \
    || die "uncommitted changes here — the live install should hold only what is committed"
  need_podman
  owner_check
}

# What a move from one commit to another asks of the running stack. `up` recreates
# everything, so it covers the other two when it is needed. doctor and promote shape no
# container and are read afresh on every run, so they need nothing; the rest of lib/
# builds what `up` creates. First match wins, so they precede lib/*.
deploy_advice() {
  local from="$1" to="$2" files f up=0 cfg=0 sb=0 other=0
  files="$(git_here diff --name-only "$from" "$to")"
  while IFS= read -r f; do
    case "$f" in
      '') ;;
      lib/doctor.sh|lib/deploy.sh)                 other=1 ;;
      bin/amphoractl|lib/*|etc/mail/*|etc/signal/*|etc/feeds/*|etc/searxng/*) up=1 ;;
      etc/config.yaml)                             cfg=1 ;;
      etc/sandbox/*)                               sb=1 ;;
      *)                                           other=1 ;;
    esac
  done <<EOF
$files
EOF
  echo "changed"
  printf '%s\n' "$files" | sed 's/^/  /'
  if [ "$up" = 1 ]; then
    c_ylw "next: amphoractl up   (recreates every container, rebuilds the sandbox, pushes config)"
  else
    if [ "$cfg" = 1 ]; then c_ylw "next: amphoractl config push"; fi
    if [ "$sb" = 1 ]; then c_ylw "next: amphoractl build-sandbox"; fi
    if [ "$cfg" = 0 ] && [ "$sb" = 0 ]; then
      info "nothing to restart — docs, tools/, doctor and promote take effect as they are"
    fi
  fi
  if [ "$other" = 1 ] && [ "$up$cfg$sb" != "000" ]; then
    info "(the rest are docs, tools/, doctor and promote, which need nothing)"
  fi
  info "then: amphoractl doctor"
}

cmd_promote() {
  local src="${1:-dev}" from to
  deploy_preflight
  git_here rev-parse --verify -q "$src^{commit}" >/dev/null || die "no branch '$src'"
  from="$(git_here rev-parse HEAD)"
  to="$(git_here rev-parse "$src")"
  if git_here merge-base --is-ancestor "$to" "$from"; then
    c_grn "main already contains $src — nothing to promote"
    return 0
  fi
  git_here merge-base --is-ancestor "$from" "$to" \
    || die "$src does not descend from main, so it cannot be fast-forwarded — rebase $src onto main first"
  git_here log --oneline "$from..$to" | sed 's/^/  /'
  cmd_backup run
  [ -n "$LAST_SNAPSHOT" ] || die "no snapshot was taken — nothing promoted"
  git_here merge --ff-only -q "$to"
  mkdir -p "$(dirname "$DEPLOY_LOG")"
  printf '%s promote %s %s %s\n' "$(date +%Y%m%d-%H%M%S)" "$from" "$to" "$LAST_SNAPSHOT" >> "$DEPLOY_LOG"
  c_grn "main is now $(git_here rev-parse --short HEAD)"
  if git_here remote get-url origin >/dev/null 2>&1; then
    git_here push -q origin main || c_ylw "  push to origin failed — main is ahead of it"
  fi
  deploy_advice "$from" "$to"
}

# One field of the most recent promote that reached HEAD: 3 is the commit it started from,
# 5 the snapshot it took (absent from promotes before that was recorded).
promote_field() {
  local head
  [ -f "$DEPLOY_LOG" ] || return 0
  head="$(git_here rev-parse HEAD 2>/dev/null)" || return 0
  awk -v h="$head" -v n="$1" '$2 == "promote" && $4 == h { p = $n } END { print p }' "$DEPLOY_LOG"
}

rollback_snapshot() { promote_field 5; }

# Back to the commit the most recent promote to HEAD started from. Code only unless
# --data, which also restores the snapshot that promote took and runs `up`: an older
# Hermes cannot run on a newer one's database, so undoing an upgrade needs both halves.
# origin is not force-pushed; fix forward on dev and promote again.
cmd_rollback() {
  local head prev a data=0 stamp dir="" v found=""
  case "${1:-}" in
    '') ;;
    --data) data=1 ;;
    *) die "usage: amphoractl rollback [--data]" ;;
  esac
  deploy_preflight
  head="$(git_here rev-parse HEAD)"
  [ -f "$DEPLOY_LOG" ] || die "no deploy log at $DEPLOY_LOG — nothing to roll back to"
  prev="$(promote_field 3)"
  [ -n "$prev" ] || die "HEAD ($(git_here rev-parse --short HEAD)) was not reached by a promote — nothing recorded to return to"
  if [ "$data" = 1 ]; then
    stamp="$(rollback_snapshot)"
    [ -n "$stamp" ] || die "that promote did not record its snapshot — use rollback, then restore <stamp>, then up"
    dir="$BACKUP_DIR/$stamp"
    for v in $BACKUP_VOLS; do
      if snapshot_archive "$dir" "$v" >/dev/null; then found="$found $v"; fi
    done
    case " $found " in
      *" $VOL_DATA "*) ;;
      *) die "snapshot $dir is missing or has no $VOL_DATA — nothing was changed" ;;
    esac
  fi
  git_here log --oneline "$prev..$head" | sed 's/^/  /'
  if [ "$data" = 1 ]; then
    c_ylw "Replaces the entire contents of:$found with snapshot $stamp"
    info "Everything since then is lost from them: sessions, memories, skills, cron changes."
    case " $found " in
      *" $VOL_SIGNAL "*) info "Signal's state goes back too, so some conversations may need a session reset." ;;
    esac
    info "The current state is snapshotted first. Project files are not touched."
    read -r -p "Roll main back to $(git_here rev-parse --short "$prev"), restore that snapshot and run up? [y/N] " a
  else
    read -r -p "Roll main back to $(git_here rev-parse --short "$prev"), dropping the commits above from this checkout? [y/N] " a
  fi
  [ "$a" = "y" ] || { echo "aborted"; return 0; }
  if [ "$data" = 1 ]; then
    # Rotation spares $stamp, because HEAD has not moved yet.
    cmd_backup run
    [ -n "$LAST_SNAPSHOT" ] || die "the current state could not be snapshotted — nothing was changed"
    info "the state before this rollback is snapshot $LAST_SNAPSHOT"
    restore_snapshot "$dir" "$found" \
      || die "restore incomplete, code not rolled back. Run: amphoractl restore $stamp, then rollback, then up"
  fi
  git_here reset -q --hard "$prev"
  printf '%s rollback %s %s\n' "$(date +%Y%m%d-%H%M%S)" "$head" "$prev" >> "$DEPLOY_LOG"
  c_grn "main is back at $(git_here rev-parse --short HEAD)"
  if git_here remote get-url origin >/dev/null 2>&1; then
    info "origin/main still has the dropped commits; the fix goes on dev, then promote"
  fi
  if [ "$data" = 1 ]; then
    # A new process: this one still holds the settings and code being rolled back.
    exec "$STACK_DIR/bin/amphoractl" up
  fi
  deploy_advice "$head" "$prev"
}
