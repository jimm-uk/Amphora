# shellcheck shell=bash
# Email: the adapter environment, the outbound relay (amphora-mail) and its secret.
# Sourced by bin/amphoractl, never run on its own.

# Email. Optional: set AMPHORA_EMAIL_ADDRESS in etc/amphora.local to switch it on. With it
# empty, nothing below reaches Hermes and no mailbox secret is required.
#
# Hermes' own IMAP/SMTP adapter, configured by process env on the hermes container like
# Signal; the password is a podman secret the sandbox never sees. Outbound mail goes through
# amphora-mail, a relay of our own that refuses any recipient outside the allowlist: the
# adapter addresses mail to whatever it is handed, send_message included, so the list has
# to be enforced below Hermes to hold. EMAIL.md.
EMAIL_ACCOUNT="${AMPHORA_EMAIL_ADDRESS:-}"      # the agent's own mailbox, never a personal one
# Word-split into podman arguments below, so whitespace is stripped rather than trusted.
EMAIL_ALLOWED="$(printf '%s' "${AMPHORA_EMAIL_ALLOWED:-}" | tr -d '[:space:]')"
EMAIL_HOME="${AMPHORA_EMAIL_HOME:-}"            # where cron jobs and proactive messages land
EMAIL_IMAP="${AMPHORA_EMAIL_IMAP_HOST:-}"
EMAIL_IMAP_PORT="${AMPHORA_EMAIL_IMAP_PORT:-}"  # empty: upstream default, 993
EMAIL_SMTP="${AMPHORA_EMAIL_SMTP_HOST:-}"       # the provider; only the relay talks to it
EMAIL_SMTP_PORT="${AMPHORA_EMAIL_SMTP_PORT:-}"  # empty: 587 (STARTTLS); 465 for implicit TLS
EMAIL_POLL="${AMPHORA_EMAIL_POLL_INTERVAL:-}"   # seconds; empty: upstream default, 15
EMAIL_AUTHSERV="${AMPHORA_EMAIL_AUTHSERV_ID:-}" # trust only this server's Authentication-Results
SECRET_EMAIL="hermes_email_password"
C_MAIL="amphora-mail"
NET_MAIL="amphora-mail-net"        # members: hermes, amphora-mail. Nothing else, ever.
IMG_MAIL="${AMPHORA_MAIL_IMAGE:-amphora-mail:local}"
MAIL_PORT=2525                    # plain SMTP: the network is the isolation, as for Signal
# Required only where a mailbox is configured, so a checkout without one never fails
# require_secrets over a secret it has no use for.
if [ -n "$EMAIL_ACCOUNT" ]; then SECRET_MAP+=("$SECRET_EMAIL:EMAIL_PASSWORD"); fi

email_enabled() { [ -n "$EMAIL_ACCOUNT" ]; }

# The mailbox's app password. Providers display these in groups of four; the spaces are
# presentation, so they are stripped rather than stored.
email_secret_set() {
  email_enabled || die "no mailbox configured — set AMPHORA_EMAIL_ADDRESS in etc/amphora.local (see etc/amphora.local.example)"
  local pw
  read -r -s -p "App password for $EMAIL_ACCOUNT: " pw; echo
  pw="$(printf '%s' "$pw" | tr -d '[:space:]')"
  [ -n "$pw" ] || die "empty password"
  printf '%s' "$pw" | podman secret create --replace "$SECRET_EMAIL" - >/dev/null
  unset pw
  c_grn "mailbox password stored as podman secret $SECRET_EMAIL"
  info "amphoractl config push hands it to Hermes"
}

# The adapter's environment as KEY=value lines, secret excluded. One source for both
# email_args() and doctor's read-back, so the two cannot disagree about what is expected.
email_env() {
  printf 'EMAIL_ADDRESS=%s\n' "$EMAIL_ACCOUNT"
  printf 'EMAIL_IMAP_HOST=%s\n' "$EMAIL_IMAP"
  # Hermes is never told the provider's SMTP host. It sends to the relay, which holds that.
  printf 'EMAIL_SMTP_HOST=mail\n'
  printf 'EMAIL_SMTP_PORT=%s\n' "$MAIL_PORT"
  printf 'EMAIL_SMTP_SECURITY=plain\n'
  if [ -n "$EMAIL_ALLOWED" ];   then printf 'EMAIL_ALLOWED_USERS=%s\n' "$EMAIL_ALLOWED"; fi
  if [ -n "$EMAIL_HOME" ];      then printf 'EMAIL_HOME_ADDRESS=%s\n' "$EMAIL_HOME"; fi
  if [ -n "$EMAIL_IMAP_PORT" ]; then printf 'EMAIL_IMAP_PORT=%s\n' "$EMAIL_IMAP_PORT"; fi
  if [ -n "$EMAIL_POLL" ];      then printf 'EMAIL_POLL_INTERVAL=%s\n' "$EMAIL_POLL"; fi
  if [ -n "$EMAIL_AUTHSERV" ];  then printf 'EMAIL_AUTHSERV_ID=%s\n' "$EMAIL_AUTHSERV"; fi
  return 0
}

# Emits the adapter's -e pairs, or nothing without a mailbox. Same word-splitting as
# signal_args(), which email_check() makes safe by refusing whitespace.
email_args() {
  email_enabled || return 0
  local kv
  printf -- '--network\n%s\n' "$NET_MAIL"
  email_env | while IFS= read -r kv; do printf -- '-e\n%s\n' "$kv"; done
  return 0
}

# A mailbox configuration Hermes could not use, or one that would corrupt the podman
# command line. Says what is wrong and returns 1; callers decide whether that is fatal.
email_check() {
  email_enabled || return 0
  local kv bad=0
  if [ -z "$EMAIL_IMAP" ] || [ -z "$EMAIL_SMTP" ]; then
    c_red "  email: AMPHORA_EMAIL_IMAP_HOST and AMPHORA_EMAIL_SMTP_HOST are both required"
    bad=1
  fi
  # One list, both directions: the adapter listens only to it and the relay sends only to it.
  if [ -z "$EMAIL_ALLOWED" ]; then
    c_red "  email: AMPHORA_EMAIL_ALLOWED is empty — nothing could be received or sent"
    bad=1
  elif [ -n "$EMAIL_HOME" ]; then
    local list home
    list=",$(printf '%s' "$EMAIL_ALLOWED" | tr '[:upper:]' '[:lower:]'),"
    home="$(printf '%s' "$EMAIL_HOME" | tr '[:upper:]' '[:lower:]')"
    case "$list" in
      *",$home,"*) ;;
      *) c_red "  email: AMPHORA_EMAIL_HOME is not in AMPHORA_EMAIL_ALLOWED — the relay would refuse it"
         bad=1 ;;
    esac
  fi
  while IFS= read -r kv; do
    case "$kv" in
      *[[:space:]]*) c_red "  email: whitespace in ${kv%%=*}"; bad=1 ;;
    esac
  done <<EOF
$(email_env)
EOF
  return $bad
}

# The client streams etc/mail/ to the machine as the build context, so it need not be a share.
build_mail() {
  local log="${TMPDIR:-/tmp}/amphoractl-mail-build.$$.log"
  [ -f "$STACK_DIR/etc/mail/Containerfile" ] || die "etc/mail/Containerfile missing"
  if ! podman build -t "$IMG_MAIL" "$STACK_DIR/etc/mail" > "$log" 2>&1; then
    tail -40 "$log" >&2
    rm -f "$log"
    die "mail relay image build failed"
  fi
  rm -f "$log"
  c_grn "  $IMG_MAIL built"
}

# Recreated whenever Hermes is, since the allowlist is fixed in its environment at create time.
# Removed outright without a mailbox, so switching email off leaves nothing running.
start_mail() {
  podman rm -f "$C_MAIL" >/dev/null 2>&1 || true
  email_enabled || return 0
  podman image exists "$IMG_MAIL" || build_mail
  podman network exists "$NET_MAIL" 2>/dev/null || podman network create "$NET_MAIL" >/dev/null
  podman run -d \
    --name "$C_MAIL" \
    --label "$OWNER_LABEL=$STACK_DIR" \
    --network "$NET_MAIL" --network-alias mail \
    --restart unless-stopped \
    --read-only --cap-drop all --security-opt no-new-privileges \
    --secret "$SECRET_EMAIL,type=env,target=RELAY_PASSWORD" \
    -e RELAY_ADDRESS="$EMAIL_ACCOUNT" \
    -e RELAY_ALLOWED="$EMAIL_ALLOWED" \
    -e RELAY_UPSTREAM_HOST="$EMAIL_SMTP" \
    -e RELAY_UPSTREAM_PORT="${EMAIL_SMTP_PORT:-587}" \
    "$IMG_MAIL" >/dev/null
}
